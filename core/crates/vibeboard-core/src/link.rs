//! Serial link to the device: handshake, heartbeat, `device_info` polling, framing and
//! disconnect detection.
//!
//! Sequence (reverse engineered, replayable):
//! 1. open the CDC port, assert DTR/RTS
//! 2. send `{"event":"transport","kind":"usb"}`
//! 3. after ~500 ms send `{"event":"transport_ready","kind":"usb"}`, start the 2 s heartbeat
//!    and poll `get_device_info` until answered
//! 4. the device answers `device_info`, after which it pushes button events and audio frames
//!
//! Losing the handshake (or seeing a reboot banner on the wire) replays the handshake instead
//! of tearing the port down.

use std::io;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::protocol::{self, AudioFrame, DeviceEvent, FrameParser, Incoming};

/// Callbacks delivered on the link worker thread. Implementations must not block for long.
///
/// Shells are expected to copy strings and marshal to their UI thread.
pub trait LinkSink: Send + Sync + 'static {
    fn on_audio(&self, frame: AudioFrame);
    fn on_event(&self, event: DeviceEvent, raw: &serde_json::Value);
    fn on_raw(&self, bytes: &[u8]);
    /// First `device_info` of a handshake: the device is ready for commands.
    fn on_ready(&self, info: &protocol::DeviceInfo);
    fn on_disconnected(&self, reason: &str);
    fn on_error(&self, message: &str);
}

#[derive(Debug, Clone)]
pub struct LinkConfig {
    pub port_name: String,
    pub baud_rate: u32,
    /// How long to wait for the first `device_info` before treating the link as dead.
    pub handshake_timeout: Duration,
    pub heartbeat_interval: Duration,
    pub device_info_interval: Duration,
    /// Delay between `transport` and `transport_ready`.
    pub transport_ready_delay: Duration,
}

impl LinkConfig {
    pub fn new(port_name: impl Into<String>) -> Self {
        Self {
            port_name: port_name.into(),
            baud_rate: 115_200,
            handshake_timeout: Duration::from_secs(8),
            heartbeat_interval: Duration::from_secs(2),
            device_info_interval: Duration::from_secs(1),
            transport_ready_delay: Duration::from_millis(500),
        }
    }
}

/// Bytes-only IO surface, so the worker can be exercised without hardware.
pub(crate) trait LinkIo: Send {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize>;
    fn write_all(&mut self, data: &[u8]) -> io::Result<()>;
}

struct SerialIo {
    port: Box<dyn serialport::SerialPort>,
}

impl LinkIo for SerialIo {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        self.port.read(buffer)
    }

    fn write_all(&mut self, data: &[u8]) -> io::Result<()> {
        use std::io::Write;
        self.port.write_all(data)?;
        self.port.flush()
    }
}

pub struct SerialLink {
    tx: Sender<Vec<u8>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl SerialLink {
    /// Opens the port synchronously (so failures surface immediately) and starts the worker.
    pub fn open(config: LinkConfig, sink: Arc<dyn LinkSink>) -> Result<Self, serialport::Error> {
        let mut port = serialport::new(&config.port_name, config.baud_rate)
            .timeout(Duration::from_millis(100))
            .open()?;
        // The firmware mirrors its UI over USB; it expects both modem lines asserted.
        let _ = port.write_data_terminal_ready(true);
        let _ = port.write_request_to_send(true);
        Ok(Self::spawn(Box::new(SerialIo { port }), config, sink))
    }

    pub(crate) fn spawn(io: Box<dyn LinkIo>, config: LinkConfig, sink: Arc<dyn LinkSink>) -> Self {
        let (tx, rx) = mpsc::channel();
        let stop = Arc::new(AtomicBool::new(false));
        let worker_stop = Arc::clone(&stop);
        let thread = thread::Builder::new()
            .name("vibeboard-link".into())
            .spawn(move || {
                let mut worker = Worker::new(io, sink, config, worker_stop, rx);
                worker.run();
            })
            .expect("spawn link worker");
        Self {
            tx,
            stop,
            thread: Some(thread),
        }
    }

    /// Queues a fully built frame for the device. The worker writes it on its next tick.
    pub fn send(&self, frame: Vec<u8>) {
        let _ = self.tx.send(frame);
    }

    pub fn send_ready(&self, session_id: u64) {
        self.send(protocol::ready_frame(session_id));
    }

    pub fn send_ui_state(&self, state: &str, text: &str) {
        self.send(protocol::ui_state_frame(state, text));
    }

    pub fn send_provision(&self, device_id: &str, secret: &str) {
        self.send(protocol::provision_frame(device_id, secret));
    }

    pub fn is_running(&self) -> bool {
        !self.stop.load(Ordering::Relaxed)
            && self
                .thread
                .as_ref()
                .map(|t| !t.is_finished())
                .unwrap_or(false)
    }

    /// Stops the worker and waits for it to release the port.
    pub fn close(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for SerialLink {
    fn drop(&mut self) {
        self.close();
    }
}

struct Worker {
    io: Box<dyn LinkIo>,
    sink: Arc<dyn LinkSink>,
    config: LinkConfig,
    stop: Arc<AtomicBool>,
    rx: Receiver<Vec<u8>>,
    parser: FrameParser,
    device_info_received: bool,
    handshake_generation: u64,
    handshake_started: Instant,
    read_buffer: Vec<u8>,
    generations: Arc<AtomicU64>,
}

impl Worker {
    fn new(
        io: Box<dyn LinkIo>,
        sink: Arc<dyn LinkSink>,
        config: LinkConfig,
        stop: Arc<AtomicBool>,
        rx: Receiver<Vec<u8>>,
    ) -> Self {
        Self {
            io,
            sink,
            config,
            stop,
            rx,
            parser: FrameParser::new(),
            device_info_received: false,
            handshake_generation: 0,
            handshake_started: Instant::now(),
            read_buffer: vec![0; 4096],
            generations: Arc::new(AtomicU64::new(0)),
        }
    }

    fn stopped(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
    }

    fn run(&mut self) {
        self.start_handshake();
        let mut last_heartbeat = Instant::now();
        let mut last_info_poll = Instant::now();

        while !self.stopped() {
            self.drain_outbox();

            match self.io.read(&mut self.read_buffer) {
                Ok(0) => {}
                Ok(count) => {
                    let data = self.read_buffer[..count].to_vec();
                    self.handle_bytes(&data);
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                    ) => {}
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => {
                    self.sink.on_disconnected(&format!("读取出错：{error}"));
                    return;
                }
            }
            if self.stopped() {
                return;
            }

            if last_heartbeat.elapsed() >= self.config.heartbeat_interval {
                last_heartbeat = Instant::now();
                self.write(&protocol::ping_frame());
            }
            if !self.device_info_received
                && last_info_poll.elapsed() >= self.config.device_info_interval
            {
                last_info_poll = Instant::now();
                self.write(&protocol::get_device_info_frame());
            }
            if !self.device_info_received
                && self.handshake_started.elapsed() >= self.config.handshake_timeout
            {
                self.sink.on_error("设备握手超时（未收到 device_info）");
                self.sink.on_disconnected("握手超时");
                return;
            }
        }
    }

    fn start_handshake(&mut self) {
        self.handshake_generation = self.generations.fetch_add(1, Ordering::SeqCst) + 1;
        self.handshake_started = Instant::now();
        self.device_info_received = false;
        self.parser.reset();
        self.write(&protocol::transport_frame());

        // Let the firmware settle into USB-mirror mode before announcing the ready state.
        let deadline = Instant::now() + self.config.transport_ready_delay;
        while Instant::now() < deadline && !self.stopped() {
            self.drain_outbox();
            thread::sleep(Duration::from_millis(10));
        }
        if self.stopped() {
            return;
        }
        self.write(&protocol::transport_ready_frame());
    }

    fn drain_outbox(&mut self) {
        loop {
            match self.rx.try_recv() {
                Ok(frame) => self.write(&frame),
                Err(_) => return,
            }
        }
    }

    fn write(&mut self, frame: &[u8]) {
        if let Err(error) = self.io.write_all(frame) {
            self.sink.on_error(&format!("写入串口失败：{error}"));
            self.stop.store(true, Ordering::SeqCst);
        }
    }

    fn handle_bytes(&mut self, data: &[u8]) {
        for incoming in self.parser.feed(data) {
            match incoming {
                Incoming::Audio(frame) => self.sink.on_audio(frame),
                Incoming::State(value) => self.handle_state(value),
                Incoming::Raw(bytes) => self.handle_raw(&bytes),
            }
        }
    }

    fn handle_state(&mut self, value: serde_json::Value) {
        let Some(event) = DeviceEvent::parse(&value) else {
            self.sink
                .on_event(DeviceEvent::Other(value.clone()), &value);
            return;
        };

        if let DeviceEvent::DeviceInfo(info) = &event {
            let first = !self.device_info_received;
            self.device_info_received = true;
            if first {
                // Recovery path for a device left in "listening": re-assert the idle screen.
                self.write(&protocol::ui_state_frame("ready", ""));
                log::info!(
                    "device handshake confirmed: id={} fw={} hw={}",
                    info.device_id,
                    info.firmware_version,
                    info.hardware
                );
                self.sink.on_ready(info);
            }
        }

        self.sink.on_event(event, &value);
    }

    fn handle_raw(&mut self, bytes: &[u8]) {
        if let Ok(text) = std::str::from_utf8(bytes) {
            if !text.is_empty() {
                log::debug!("device raw: {text}");
                if text.contains("Rebooting")
                    || text.contains("host response timeout, disconnecting")
                {
                    log::info!("device reset detected — replaying handshake");
                    self.start_handshake();
                    return;
                }
            }
        }
        self.sink.on_raw(bytes);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::AudioFrame;
    use std::collections::VecDeque;
    use std::sync::Mutex;

    #[derive(Default)]
    struct FakeIo {
        inbound: Arc<Mutex<VecDeque<u8>>>,
        writes: Arc<Mutex<Vec<Vec<u8>>>>,
    }

    impl LinkIo for FakeIo {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            let mut queue = self.inbound.lock().unwrap();
            if queue.is_empty() {
                drop(queue);
                thread::sleep(Duration::from_millis(2));
                return Err(io::Error::new(io::ErrorKind::TimedOut, "no data"));
            }
            let count = queue.len().min(buffer.len());
            for slot in buffer.iter_mut().take(count) {
                *slot = queue.pop_front().unwrap();
            }
            Ok(count)
        }

        fn write_all(&mut self, data: &[u8]) -> io::Result<()> {
            self.writes.lock().unwrap().push(data.to_vec());
            Ok(())
        }
    }

    #[derive(Default)]
    struct RecordingSink {
        audio: Mutex<Vec<AudioFrame>>,
        events: Mutex<Vec<DeviceEvent>>,
        raw: Mutex<Vec<String>>,
        ready: Mutex<u32>,
        errors: Mutex<Vec<String>>,
        disconnected: Mutex<Vec<String>>,
    }

    impl LinkSink for RecordingSink {
        fn on_audio(&self, frame: AudioFrame) {
            self.audio.lock().unwrap().push(frame);
        }
        fn on_event(&self, event: DeviceEvent, _raw: &serde_json::Value) {
            self.events.lock().unwrap().push(event);
        }
        fn on_raw(&self, bytes: &[u8]) {
            self.raw
                .lock()
                .unwrap()
                .push(String::from_utf8_lossy(bytes).to_string());
        }
        fn on_ready(&self, _info: &protocol::DeviceInfo) {
            *self.ready.lock().unwrap() += 1;
        }
        fn on_disconnected(&self, reason: &str) {
            self.disconnected.lock().unwrap().push(reason.to_string());
        }
        fn on_error(&self, message: &str) {
            self.errors.lock().unwrap().push(message.to_string());
        }
    }

    fn fast_config() -> LinkConfig {
        LinkConfig {
            port_name: "fake".into(),
            baud_rate: 115_200,
            handshake_timeout: Duration::from_secs(5),
            heartbeat_interval: Duration::from_millis(5),
            device_info_interval: Duration::from_millis(5),
            transport_ready_delay: Duration::from_millis(10),
        }
    }

    fn device_info_frame() -> Vec<u8> {
        crate::protocol::state_frame(
            br#"{"event":"device_info","device_id":"VS-1","hardware":"vibe_keyboard","firmware_version":"0.3.8","provisioned":true}"#,
        )
    }

    fn audio_bytes(session: u32) -> Vec<u8> {
        let payload = [1u8, 2, 3, 4];
        let mut out = vec![0x01, 0x01];
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(&session.to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
        out.push(0x02);
        out.push(0);
        out.extend_from_slice(&(payload.len() as u16).to_le_bytes());
        out.extend_from_slice(&payload);
        out
    }

    fn wait_until(mut predicate: impl FnMut() -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if predicate() {
                return true;
            }
            thread::sleep(Duration::from_millis(5));
        }
        false
    }

    #[test]
    fn handshake_sends_transport_then_ready() {
        let io = FakeIo::default();
        let writes = Arc::clone(&io.writes);
        let sink = Arc::new(RecordingSink::default());
        let mut link = SerialLink::spawn(Box::new(io), fast_config(), sink);

        assert!(wait_until(|| writes.lock().unwrap().len() >= 2));
        let frames = writes.lock().unwrap().clone();
        assert_eq!(frames[0], protocol::transport_frame());
        assert!(frames
            .iter()
            .any(|f| f == &protocol::transport_ready_frame()));
        // device_info polling and the heartbeat both start after the ready frame.
        assert!(wait_until(|| writes
            .lock()
            .unwrap()
            .iter()
            .any(|f| f == &protocol::get_device_info_frame())));
        assert!(wait_until(|| writes
            .lock()
            .unwrap()
            .iter()
            .any(|f| f == &protocol::ping_frame())));
        link.close();
    }

    #[test]
    fn device_info_marks_ready_and_resets_screen() {
        let io = FakeIo::default();
        io.inbound.lock().unwrap().extend(device_info_frame());
        let writes = Arc::clone(&io.writes);
        let sink = Arc::new(RecordingSink::default());
        let sink_dyn: Arc<dyn LinkSink> = sink.clone();
        let mut link = SerialLink::spawn(Box::new(io), fast_config(), sink_dyn);

        assert!(wait_until(|| *sink.ready.lock().unwrap() == 1));
        assert!(writes
            .lock()
            .unwrap()
            .iter()
            .any(|frame| frame == &protocol::ui_state_frame("ready", "")));
        link.close();
    }

    #[test]
    fn audio_and_button_events_are_delivered() {
        let io = FakeIo::default();
        {
            let mut queue = io.inbound.lock().unwrap();
            queue.extend(device_info_frame());
            queue.extend(audio_bytes(15));
            queue.extend(crate::protocol::state_frame(
                br#"{"event":"button_down","button":"K4","session_id":15}"#,
            ));
        }
        let sink = Arc::new(RecordingSink::default());
        let sink_dyn: Arc<dyn LinkSink> = sink.clone();
        let mut link = SerialLink::spawn(Box::new(io), fast_config(), sink_dyn);

        assert!(wait_until(|| !sink.audio.lock().unwrap().is_empty()));
        let frame = sink.audio.lock().unwrap()[0].clone();
        assert_eq!(frame.session_id, 15);
        assert!(frame.is_last());
        assert!(wait_until(|| sink.events.lock().unwrap().iter().any(
            |e| matches!(e, DeviceEvent::ButtonDown { button, .. } if button == "k4")
        )));
        link.close();
    }

    #[test]
    fn reboot_banner_replays_handshake() {
        let io = FakeIo::default();
        io.inbound
            .lock()
            .unwrap()
            .extend(b"Rebooting...\n".iter().copied());
        let writes = Arc::clone(&io.writes);
        let sink = Arc::new(RecordingSink::default());
        let mut link = SerialLink::spawn(Box::new(io), fast_config(), sink);

        assert!(wait_until(|| writes
            .lock()
            .unwrap()
            .iter()
            .filter(|frame| *frame == &protocol::transport_frame())
            .count()
            >= 2));
        link.close();
    }

    #[test]
    fn ui_state_and_provision_are_queued() {
        let io = FakeIo::default();
        let writes = Arc::clone(&io.writes);
        let sink = Arc::new(RecordingSink::default());
        let mut link = SerialLink::spawn(Box::new(io), fast_config(), sink);

        link.send_ui_state("recording", "");
        link.send_provision("VS-1", "secret");
        assert!(wait_until(|| {
            let frames = writes.lock().unwrap();
            frames
                .iter()
                .any(|f| f == &protocol::ui_state_frame("recording", ""))
                && frames
                    .iter()
                    .any(|f| f == &protocol::provision_frame("VS-1", "secret"))
        }));
        link.close();
    }
}
