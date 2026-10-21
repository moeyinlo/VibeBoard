//! Session orchestration: button semantics, recording lifecycle, provider selection,
//! timeouts and output routing.
//!
//! Everything runs on one worker thread fed by a message queue, so device events, provider
//! results and timer ticks are processed in a deterministic order without locking the state
//! machine. Providers deliver their results by sending messages back into the same queue.

use std::collections::HashMap;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::asr::stepfun_batch::StepFunBatchAsr;
use crate::asr::stepfun_stream::StepFunStreamAsr;
use crate::asr::{AsrProvider, AsrSink};
use crate::button::{ButtonAction, ButtonRouter, Command};
use crate::opus::OpusPcmDecoder;
use crate::protocol::{AudioFrame, DeviceInfo};
use crate::rewrite;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderChoice {
    /// StepFun cloud, streaming or batch depending on the model name.
    StepFun,
    /// Local whisper.cpp model handled inside the core.
    Whisper,
    /// The shell's own recogniser (Apple Speech / System.Speech); PCM is handed over.
    External,
}

impl ProviderChoice {
    pub fn parse(value: &str) -> Option<Self> {
        match value.to_ascii_lowercase().as_str() {
            "stepfun" => Some(ProviderChoice::StepFun),
            "whisper" => Some(ProviderChoice::Whisper),
            "external" | "apple" | "windows" => Some(ProviderChoice::External),
            _ => None,
        }
    }

    pub fn is_cloud(self) -> bool {
        self == ProviderChoice::StepFun
    }
}

#[derive(Debug, Clone)]
pub struct SessionConfig {
    pub provider: ProviderChoice,
    pub model: String,
    /// Local Whisper model name (`base`, `small`, ...) or an explicit path.
    pub whisper_model: String,
    pub recognition_key: String,
    pub rewrite_enabled: bool,
    pub rewrite_model: String,
    pub rewrite_key: String,
    pub button_actions: HashMap<String, ButtonAction>,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            provider: ProviderChoice::StepFun,
            model: "stepaudio-2.5-asr-stream".into(),
            whisper_model: "small".into(),
            recognition_key: String::new(),
            rewrite_enabled: false,
            rewrite_model: "step-3.5-flash".into(),
            rewrite_key: String::new(),
            button_actions: HashMap::new(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SessionTimings {
    /// Queue poll interval, also the timer resolution.
    pub tick: Duration,
    /// After the button is released, how long to wait for the device's final audio frame.
    pub audio_end: Duration,
    pub final_local: Duration,
    pub final_cloud: Duration,
}

impl Default for SessionTimings {
    fn default() -> Self {
        Self {
            tick: Duration::from_millis(20),
            audio_end: Duration::from_millis(1000),
            final_local: Duration::from_secs(30),
            final_cloud: Duration::from_secs(60),
        }
    }
}

// ---------------------------------------------------------------------------
// Shell-facing traits
// ---------------------------------------------------------------------------

/// Output side: tray status, overlay text, insertion into the focused app.
pub trait SessionSink: Send + Sync + 'static {
    fn status(&self, text: &str);
    fn partial_text(&self, text: &str);
    fn final_text(&self, text: &str);
    fn session_started(&self);
    /// Recognition ended without text (cancel, timeout, device loss).
    fn cancelled(&self);
    fn error(&self, message: &str);
    /// A non-recognition button was pressed: copyResult / showResult / paste / undo / enter / escape.
    fn action(&self, _action: &str) {}
    /// Local recognition diagnostics (backend, RTF, memory); cloud providers do not emit this.
    fn local_stats(&self, _stats: &crate::asr::LocalStats) {}
    /// External provider path: decoded PCM for the shell's own recogniser.
    fn external_pcm(&self, _pcm: &[u8]) {}
    fn external_pcm_end(&self) {}
}

/// Device side: screen state pushed back to the hardware.
pub trait DeviceCommands: Send + Sync + 'static {
    fn ready(&self, session_id: u64);
    fn ui_state(&self, state: &str, text: &str);
}

impl DeviceCommands for crate::link::SerialLink {
    fn ready(&self, session_id: u64) {
        self.send_ready(session_id);
    }

    fn ui_state(&self, state: &str, text: &str) {
        self.send_ui_state(state, text);
    }
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub enum SessionMessage {
    ButtonDown {
        button: String,
        session_id: u64,
    },
    ButtonUp {
        button: String,
        session_id: u64,
    },
    ButtonClick {
        button: String,
    },
    Audio(AudioFrame),
    Ready(Box<DeviceInfo>),
    Disconnected,
    Cancel,
    /// Result of the shell-side recogniser.
    ExternalText {
        text: String,
        is_final: bool,
    },
    ProviderText {
        text: String,
        is_final: bool,
    },
    ProviderStats(Box<crate::asr::LocalStats>),
    ProviderError(String),
    RewriteDone(String),
    SetConfig(Box<SessionConfig>),
    Shutdown,
}

pub type ProviderFactory = dyn Fn(&SessionConfig, Arc<dyn AsrSink>) -> Result<Option<Box<dyn AsrProvider>>, String>
    + Send
    + Sync;

// ---------------------------------------------------------------------------
// Session handle
// ---------------------------------------------------------------------------

pub struct Session {
    tx: Sender<SessionMessage>,
    thread: Option<JoinHandle<()>>,
}

impl Session {
    pub fn spawn(
        config: SessionConfig,
        sink: Arc<dyn SessionSink>,
        device: Arc<dyn DeviceCommands>,
    ) -> Self {
        Self::spawn_with(
            config,
            sink,
            device,
            Arc::new(default_provider),
            SessionTimings::default(),
        )
    }

    pub fn spawn_with(
        config: SessionConfig,
        sink: Arc<dyn SessionSink>,
        device: Arc<dyn DeviceCommands>,
        factory: Arc<ProviderFactory>,
        timings: SessionTimings,
    ) -> Self {
        let (tx, rx) = mpsc::channel();
        let worker_tx = tx.clone();
        let thread = thread::Builder::new()
            .name("vibeboard-session".into())
            .spawn(move || {
                let mut worker = Worker {
                    config,
                    sink,
                    device,
                    factory,
                    timings,
                    tx: worker_tx,
                    decoder: OpusPcmDecoder::new().ok(),
                    router: ButtonRouter::new(),
                    provider: None,
                    recording_button: None,
                    recording_session: None,
                    session_frames: 0,
                    active: false,
                    awaiting_final: false,
                    awaiting_rewrite: false,
                    audio_end_deadline: None,
                    final_deadline: None,
                };
                worker.run(rx);
            })
            .expect("spawn session worker");
        Self {
            tx,
            thread: Some(thread),
        }
    }

    pub fn send(&self, message: SessionMessage) {
        let _ = self.tx.send(message);
    }

    /// Convenience wrappers used by the shells and the CLI.
    pub fn button_down(&self, button: impl Into<String>, session_id: u64) {
        self.send(SessionMessage::ButtonDown {
            button: button.into(),
            session_id,
        });
    }

    pub fn button_up(&self, button: impl Into<String>) {
        self.send(SessionMessage::ButtonUp {
            button: button.into(),
            session_id: 0,
        });
    }

    pub fn cancel(&self) {
        self.send(SessionMessage::Cancel);
    }

    pub fn update_config(&self, config: SessionConfig) {
        self.send(SessionMessage::SetConfig(Box::new(config)));
    }

    pub fn stop(&mut self) {
        let _ = self.tx.send(SessionMessage::Shutdown);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.tx.send(SessionMessage::Shutdown);
        // Do not join here: drop may run on the worker's own thread chain via callbacks.
        self.thread.take();
    }
}

pub fn default_provider(
    config: &SessionConfig,
    sink: Arc<dyn AsrSink>,
) -> Result<Option<Box<dyn AsrProvider>>, String> {
    match config.provider {
        ProviderChoice::StepFun => {
            if config.model.ends_with("-stream") {
                Ok(Some(Box::new(StepFunStreamAsr::new(
                    config.model.clone(),
                    config.recognition_key.clone(),
                    sink,
                ))))
            } else {
                Ok(Some(Box::new(StepFunBatchAsr::new(
                    config.model.clone(),
                    config.recognition_key.clone(),
                    sink,
                ))))
            }
        }
        ProviderChoice::Whisper => {
            #[cfg(feature = "whisper")]
            {
                let path = crate::models::resolve(&config.whisper_model)
                    .unwrap_or_else(|| crate::models::path_for(&config.whisper_model));
                Ok(Some(Box::new(crate::asr::whisper::WhisperAsr::new(
                    path, sink,
                ))))
            }
            #[cfg(not(feature = "whisper"))]
            {
                let _ = sink;
                Err("此构建未启用本地 Whisper（请用 --features whisper 重新构建）".into())
            }
        }
        ProviderChoice::External => Ok(None),
    }
}

/// Bridges provider callbacks back into the session queue.
struct ChannelSink(Mutex<Sender<SessionMessage>>);

impl AsrSink for ChannelSink {
    fn on_text(&self, text: &str, is_final: bool) {
        if let Ok(tx) = self.0.lock() {
            let _ = tx.send(SessionMessage::ProviderText {
                text: text.to_string(),
                is_final,
            });
        }
    }

    fn on_error(&self, message: &str) {
        if let Ok(tx) = self.0.lock() {
            let _ = tx.send(SessionMessage::ProviderError(message.to_string()));
        }
    }

    fn on_stats(&self, stats: &crate::asr::LocalStats) {
        if let Ok(tx) = self.0.lock() {
            let _ = tx.send(SessionMessage::ProviderStats(Box::new(stats.clone())));
        }
    }
}

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

struct Worker {
    config: SessionConfig,
    sink: Arc<dyn SessionSink>,
    device: Arc<dyn DeviceCommands>,
    factory: Arc<ProviderFactory>,
    timings: SessionTimings,
    tx: Sender<SessionMessage>,
    decoder: Option<OpusPcmDecoder>,
    router: ButtonRouter,
    provider: Option<Box<dyn AsrProvider>>,
    recording_button: Option<String>,
    recording_session: Option<u64>,
    session_frames: u64,
    active: bool,
    awaiting_final: bool,
    awaiting_rewrite: bool,
    audio_end_deadline: Option<Instant>,
    final_deadline: Option<Instant>,
}

impl Worker {
    fn run(&mut self, rx: Receiver<SessionMessage>) {
        loop {
            match rx.recv_timeout(self.timings.tick) {
                Ok(SessionMessage::Shutdown) | Err(RecvTimeoutError::Disconnected) => break,
                Ok(message) => self.handle(message),
                Err(RecvTimeoutError::Timeout) => {}
            }
            if !self.tick() {
                break;
            }
        }
        self.stop_provider();
    }

    fn handle(&mut self, message: SessionMessage) {
        match message {
            SessionMessage::ButtonDown { button, session_id } => {
                self.button_down(&button, session_id)
            }
            SessionMessage::ButtonUp { button, .. } => self.button_up(&button),
            SessionMessage::ButtonClick { button } => self.button_click(&button),
            SessionMessage::Audio(frame) => self.audio(frame),
            SessionMessage::Ready(info) => {
                self.sink.status("设备已连接");
                log::info!(
                    "设备就绪 id={} fw={} hw={}",
                    info.device_id,
                    info.firmware_version,
                    info.hardware
                );
            }
            SessionMessage::Disconnected => self.disconnected(),
            SessionMessage::Cancel => self.cancel_recognition(),
            SessionMessage::ExternalText { text, is_final } => self.provider_text(&text, is_final),
            SessionMessage::ProviderText { text, is_final } => self.provider_text(&text, is_final),
            SessionMessage::ProviderStats(stats) => {
                log::info!("本地识别统计：{}", stats.summary());
                self.sink.local_stats(&stats);
            }
            SessionMessage::ProviderError(message) => {
                log::warn!("识别错误：{message}");
                if self.active || self.awaiting_final {
                    self.complete_recognition("");
                }
                self.sink.error(&message);
            }
            SessionMessage::RewriteDone(text) => {
                if self.awaiting_rewrite {
                    self.awaiting_rewrite = false;
                    self.sink.final_text(&text);
                    self.sink.status("识别完成");
                }
            }
            SessionMessage::SetConfig(config) => {
                self.config = *config;
                log::info!(
                    "会话配置更新 provider={:?} model={}",
                    self.config.provider,
                    self.config.model
                );
            }
            SessionMessage::Shutdown => {}
        }
    }

    // ---- buttons ----

    fn action_for(&self, button: &str) -> ButtonAction {
        self.config
            .button_actions
            .get(button)
            .copied()
            .unwrap_or(ButtonAction::Voice)
    }

    fn button_down(&mut self, button: &str, session_id: u64) {
        let action = self.action_for(button);
        let routed = self.router.down(button, session_id, action);
        if let Some(routed) = routed {
            match routed.command {
                Command::Start => self.start_recording(button, session_id),
                Command::Toggle => self.toggle_recording(button, session_id),
                Command::Action(action) => self.perform_action(action),
                Command::Finish => {}
            }
        }
    }

    fn button_up(&mut self, button: &str) {
        if let Some(routed) = self.router.up(button) {
            if routed.command == Command::Finish && self.recording_button.as_deref() == Some(button)
            {
                self.begin_waiting_audio_end();
            }
        }
    }

    fn button_click(&mut self, button: &str) {
        let action = self.action_for(button);
        if let Some(routed) = self.router.click(button, action) {
            match routed.command {
                Command::Toggle => self.toggle_recording(button, 0),
                Command::Action(action) => self.perform_action(action),
                Command::Start | Command::Finish => {}
            }
        }
    }

    fn toggle_recording(&mut self, button: &str, session_id: u64) {
        if self.active {
            if self.recording_button.as_deref() == Some(button) {
                self.begin_waiting_audio_end();
            }
        } else if !self.awaiting_final {
            self.start_recording(button, session_id);
        }
    }

    fn perform_action(&mut self, action: ButtonAction) {
        if action == ButtonAction::Cancel {
            self.cancel_recognition();
            return;
        }
        if !self.active && !self.awaiting_final {
            self.device.ui_state("ready", "");
        }
        // The shells own clipboard/keyboard behaviour; the core only reports the action.
        self.sink.action(action.as_str());
    }

    // ---- recording lifecycle ----

    fn start_recording(&mut self, button: &str, session_id: u64) {
        if self.active || self.awaiting_final {
            return;
        }
        self.recording_button = Some(button.to_string());
        self.recording_session = (session_id != 0).then_some(session_id);
        self.device.ready(session_id);
        self.start_session();
    }

    fn start_session(&mut self) {
        let sink: Arc<dyn AsrSink> = Arc::new(ChannelSink(Mutex::new(self.tx.clone())));
        let provider = match (self.factory)(&self.config, sink) {
            Ok(provider) => provider,
            Err(message) => {
                self.sink.error(&message);
                self.sink.status("识别服务尚未就绪");
                self.reset_recording();
                self.device.ui_state("ready", "");
                return;
            }
        };

        if let Some(mut provider) = provider {
            if let Err(message) = provider.start() {
                self.sink.error(&message);
                self.sink.status("识别服务尚未就绪");
                self.reset_recording();
                self.device.ui_state("ready", "");
                return;
            }
            self.provider = Some(provider);
        }

        self.session_frames = 0;
        self.active = true;
        self.awaiting_final = false;
        self.device.ui_state("recording", "");
        self.sink.session_started();
        self.sink.status("正在聆听");
        log::info!(
            "开始识别 button={:?} provider={:?} model={} session={:?}",
            self.recording_button,
            self.config.provider,
            self.config.model,
            self.recording_session
        );
    }

    fn begin_waiting_audio_end(&mut self) {
        if !self.active || self.audio_end_deadline.is_some() {
            return;
        }
        log::info!("按键已松开，等待设备音频末帧");
        self.device.ui_state("thinking", "");
        self.sink.status("正在生成识别结果");
        self.audio_end_deadline = Some(Instant::now() + self.timings.audio_end);
    }

    fn finish_session(&mut self) {
        if !self.active {
            return;
        }
        self.audio_end_deadline = None;
        self.active = false;
        self.awaiting_final = true;
        self.device.ui_state("thinking", "");
        self.sink.status("正在生成识别结果");
        log::info!("结束音频输入：{} 帧", self.session_frames);

        match self.provider.as_mut() {
            Some(provider) => provider.finish(),
            None => self.sink.external_pcm_end(),
        }

        let timeout = if self.config.provider.is_cloud() {
            self.timings.final_cloud
        } else {
            self.timings.final_local
        };
        self.final_deadline = Some(Instant::now() + timeout);
    }

    fn provider_text(&mut self, text: &str, is_final: bool) {
        if !self.active && !self.awaiting_final {
            return;
        }
        if is_final {
            self.complete_recognition(text);
        } else {
            self.sink.partial_text(text);
        }
    }

    fn complete_recognition(&mut self, text: &str) {
        self.audio_end_deadline = None;
        self.final_deadline = None;
        self.active = false;
        self.awaiting_final = false;
        self.recording_button = None;
        self.recording_session = None;
        self.stop_provider();
        log::info!("识别完成：{} 字符", text.chars().count());
        self.device.ui_state("ready", text);

        if text.is_empty() {
            self.sink.final_text("");
            self.sink.status("未识别到文字");
            return;
        }

        if self.config.rewrite_enabled && !self.config.rewrite_key.trim().is_empty() {
            self.sink.partial_text(text);
            self.sink.status("正在整理");
            self.awaiting_rewrite = true;
            let original = text.to_string();
            let model = self.config.rewrite_model.clone();
            let key = self.config.rewrite_key.clone();
            let tx = self.tx.clone();
            let _ = thread::Builder::new()
                .name("vibeboard-rewrite".into())
                .spawn(move || {
                    let result =
                        rewrite::rewrite(&original, &model, &key).unwrap_or_else(|error| {
                            log::warn!("语义整理失败：{error}");
                            original
                        });
                    let _ = tx.send(SessionMessage::RewriteDone(result));
                });
            return;
        }

        self.sink.final_text(text);
        self.sink.status("识别完成");
    }

    fn cancel_recognition(&mut self) {
        self.audio_end_deadline = None;
        self.final_deadline = None;
        self.active = false;
        self.awaiting_final = false;
        self.awaiting_rewrite = false;
        self.reset_recording();
        self.stop_provider();
        self.device.ui_state("ready", "");
        self.sink.cancelled();
        self.sink.status("已取消识别");
    }

    fn disconnected(&mut self) {
        self.audio_end_deadline = None;
        self.final_deadline = None;
        self.active = false;
        self.awaiting_final = false;
        self.awaiting_rewrite = false;
        self.reset_recording();
        self.router.reset();
        self.stop_provider();
        self.sink.cancelled();
        self.sink.status("设备已断开");
    }

    fn reset_recording(&mut self) {
        self.recording_button = None;
        self.recording_session = None;
        self.session_frames = 0;
    }

    fn stop_provider(&mut self) {
        if let Some(mut provider) = self.provider.take() {
            provider.stop();
        }
    }

    // ---- audio ----

    fn audio(&mut self, frame: AudioFrame) {
        if !self.active {
            return;
        }
        if let Some(session) = self.recording_session {
            if frame.session_id as u64 != session {
                if frame.is_last() {
                    log::debug!(
                        "忽略其他会话末帧 session={} current={}",
                        frame.session_id,
                        session
                    );
                }
                return;
            }
        }
        self.session_frames += 1;
        if self.session_frames == 1 || self.session_frames % 50 == 0 || frame.is_last() {
            log::debug!(
                "音频 #{} session={} seq={} bytes={} flags=0x{:x} last={}",
                self.session_frames,
                frame.session_id,
                frame.sequence,
                frame.payload.len(),
                frame.flags,
                frame.is_last()
            );
        }

        if !frame.payload.is_empty() {
            let pcm = match self.decoder.as_mut() {
                Some(decoder) => decoder
                    .decode_to_pcm16(&frame.payload)
                    .unwrap_or_else(|error| {
                        log::warn!("Opus 解码失败 seq={}: {error}", frame.sequence);
                        Vec::new()
                    }),
                None => Vec::new(),
            };
            if !pcm.is_empty() {
                match self.provider.as_mut() {
                    Some(provider) => provider.send_pcm(&pcm),
                    None => self.sink.external_pcm(&pcm),
                }
            }
        }

        if frame.is_last() {
            self.finish_session();
        }
    }

    // ---- timers ----

    /// Returns false when the worker should exit.
    fn tick(&mut self) -> bool {
        let now = Instant::now();
        if let Some(deadline) = self.audio_end_deadline {
            if now >= deadline {
                log::info!(
                    "等待末帧超时，使用已收到的 {} 帧结束识别",
                    self.session_frames
                );
                self.audio_end_deadline = None;
                self.finish_session();
            }
        }
        if let Some(deadline) = self.final_deadline {
            if now >= deadline {
                self.final_deadline = None;
                log::warn!("识别超时");
                self.complete_recognition("");
                self.sink.status("识别超时，请重试");
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use audiopus::coder::Encoder;
    use audiopus::{Application, Channels, SampleRate};
    use std::sync::atomic::{AtomicU64, Ordering};

    #[derive(Default)]
    struct FakeDevice {
        ready: Mutex<Vec<u64>>,
        ui_states: Mutex<Vec<(String, String)>>,
    }

    impl DeviceCommands for FakeDevice {
        fn ready(&self, session_id: u64) {
            self.ready.lock().unwrap().push(session_id);
        }
        fn ui_state(&self, state: &str, text: &str) {
            self.ui_states
                .lock()
                .unwrap()
                .push((state.to_string(), text.to_string()));
        }
    }

    #[derive(Default)]
    struct FakeSink {
        statuses: Mutex<Vec<String>>,
        partials: Mutex<Vec<String>>,
        finals: Mutex<Vec<String>>,
        errors: Mutex<Vec<String>>,
        actions: Mutex<Vec<String>>,
        started: AtomicU64,
        cancelled: AtomicU64,
        external_pcm: Mutex<Vec<u8>>,
    }

    impl SessionSink for FakeSink {
        fn status(&self, text: &str) {
            self.statuses.lock().unwrap().push(text.to_string());
        }
        fn partial_text(&self, text: &str) {
            self.partials.lock().unwrap().push(text.to_string());
        }
        fn final_text(&self, text: &str) {
            self.finals.lock().unwrap().push(text.to_string());
        }
        fn session_started(&self) {
            self.started.fetch_add(1, Ordering::Relaxed);
        }
        fn cancelled(&self) {
            self.cancelled.fetch_add(1, Ordering::Relaxed);
        }
        fn error(&self, message: &str) {
            self.errors.lock().unwrap().push(message.to_string());
        }
        fn action(&self, action: &str) {
            self.actions.lock().unwrap().push(action.to_string());
        }
        fn external_pcm(&self, pcm: &[u8]) {
            self.external_pcm.lock().unwrap().extend_from_slice(pcm);
        }
    }

    #[derive(Default)]
    struct FakeProviderState {
        log: Mutex<Vec<String>>,
        pcm: Mutex<Vec<u8>>,
        emit_final: bool,
    }

    struct FakeProvider {
        sink: Arc<dyn AsrSink>,
        state: Arc<FakeProviderState>,
        emit_final: bool,
    }

    impl AsrProvider for FakeProvider {
        fn name(&self) -> &'static str {
            "fake"
        }
        fn start(&mut self) -> Result<(), String> {
            self.state.log.lock().unwrap().push("start".into());
            Ok(())
        }
        fn send_pcm(&mut self, pcm16: &[u8]) {
            self.state.pcm.lock().unwrap().extend_from_slice(pcm16);
        }
        fn finish(&mut self) {
            self.state.log.lock().unwrap().push("finish".into());
            if self.emit_final {
                self.sink.on_text("你好，世界", true);
            }
        }
        fn stop(&mut self) {
            self.state.log.lock().unwrap().push("stop".into());
        }
    }

    fn encode_frame(samples: usize) -> Vec<u8> {
        let encoder = Encoder::new(SampleRate::Hz16000, Channels::Mono, Application::Voip).unwrap();
        let pcm: Vec<i16> = (0..samples)
            .map(|i| {
                ((i as f32 * 2.0 * std::f32::consts::PI * 440.0 / 16_000.0).sin() * 6000.0) as i16
            })
            .collect();
        let mut packet = vec![0u8; 4000];
        let len = encoder.encode(&pcm[..], &mut packet).unwrap();
        packet.truncate(len);
        packet
    }

    fn audio_frame(session: u32, last: bool) -> AudioFrame {
        AudioFrame {
            session_id: session,
            sequence: 0,
            flags: if last { 0x02 } else { 0 },
            payload: if last { Vec::new() } else { encode_frame(320) },
        }
    }

    fn timings() -> SessionTimings {
        SessionTimings {
            tick: Duration::from_millis(5),
            audio_end: Duration::from_millis(80),
            final_local: Duration::from_millis(300),
            final_cloud: Duration::from_millis(300),
        }
    }

    struct Harness {
        session: Session,
        sink: Arc<FakeSink>,
        device: Arc<FakeDevice>,
        provider: Arc<FakeProviderState>,
    }

    fn harness(provider_emits_final: bool) -> Harness {
        let sink = Arc::new(FakeSink::default());
        let device = Arc::new(FakeDevice::default());
        let provider = Arc::new(FakeProviderState {
            emit_final: provider_emits_final,
            ..Default::default()
        });
        let provider_for_factory = Arc::clone(&provider);
        let factory: Arc<ProviderFactory> = Arc::new(move |_config, sink| {
            Ok(Some(Box::new(FakeProvider {
                sink,
                state: Arc::clone(&provider_for_factory),
                emit_final: provider_for_factory.emit_final,
            }) as Box<dyn AsrProvider>))
        });
        let config = SessionConfig {
            provider: ProviderChoice::StepFun,
            ..Default::default()
        };
        let session = Session::spawn_with(config, sink.clone(), device.clone(), factory, timings());
        Harness {
            session,
            sink,
            device,
            provider,
        }
    }

    fn wait_until(mut predicate: impl FnMut() -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if predicate() {
                return true;
            }
            thread::sleep(Duration::from_millis(5));
        }
        false
    }

    #[test]
    fn button_down_starts_a_session() {
        let mut harness = harness(false);
        harness.session.button_down("k4", 7);
        assert!(wait_until(|| !harness
            .device
            .ui_states
            .lock()
            .unwrap()
            .is_empty()));
        assert_eq!(*harness.device.ready.lock().unwrap(), vec![7]);
        assert_eq!(
            harness.device.ui_states.lock().unwrap()[0],
            ("recording".to_string(), String::new())
        );
        assert_eq!(harness.sink.started.load(Ordering::Relaxed), 1);
        assert!(harness
            .provider
            .log
            .lock()
            .unwrap()
            .contains(&"start".to_string()));
        harness.session.stop();
    }

    #[test]
    fn audio_is_decoded_and_final_text_reaches_the_device() {
        let mut harness = harness(true);
        harness.session.button_down("k4", 7);
        assert!(wait_until(
            || harness.sink.started.load(Ordering::Relaxed) == 1
        ));

        harness
            .session
            .send(SessionMessage::Audio(audio_frame(7, false)));
        harness
            .session
            .send(SessionMessage::Audio(audio_frame(7, true)));

        assert!(wait_until(|| !harness
            .sink
            .finals
            .lock()
            .unwrap()
            .is_empty()));
        assert_eq!(harness.sink.finals.lock().unwrap()[0], "你好，世界");
        assert!(
            harness.provider.pcm.lock().unwrap().len() >= 640,
            "20 ms of PCM16 at 16 kHz"
        );

        let last_ui = harness
            .device
            .ui_states
            .lock()
            .unwrap()
            .last()
            .cloned()
            .unwrap();
        assert_eq!(last_ui, ("ready".to_string(), "你好，世界".to_string()));
        harness.session.stop();
    }

    #[test]
    fn release_without_final_frame_finishes_on_timeout() {
        let mut harness = harness(true);
        harness.session.button_down("k4", 7);
        assert!(wait_until(
            || harness.sink.started.load(Ordering::Relaxed) == 1
        ));
        harness.session.button_up("k4");

        assert!(wait_until(|| harness
            .provider
            .log
            .lock()
            .unwrap()
            .contains(&"finish".to_string())));
        assert!(wait_until(|| !harness
            .sink
            .finals
            .lock()
            .unwrap()
            .is_empty()));
        harness.session.stop();
    }

    #[test]
    fn missing_result_hits_the_final_timeout() {
        let mut harness = harness(false);
        harness.session.button_down("k4", 7);
        assert!(wait_until(
            || harness.sink.started.load(Ordering::Relaxed) == 1
        ));
        harness
            .session
            .send(SessionMessage::Audio(audio_frame(7, true)));

        assert!(wait_until(|| !harness
            .sink
            .finals
            .lock()
            .unwrap()
            .is_empty()));
        assert_eq!(harness.sink.finals.lock().unwrap()[0], "");
        assert!(harness
            .sink
            .statuses
            .lock()
            .unwrap()
            .iter()
            .any(|s| s.contains("超时")));
        harness.session.stop();
    }

    #[test]
    fn cancel_stops_the_session_and_restores_the_device_screen() {
        let mut harness = harness(false);
        harness.session.button_down("k4", 7);
        assert!(wait_until(
            || harness.sink.started.load(Ordering::Relaxed) == 1
        ));
        harness.session.cancel();

        assert!(wait_until(|| harness
            .sink
            .cancelled
            .load(Ordering::Relaxed)
            == 1));
        let ui = harness
            .device
            .ui_states
            .lock()
            .unwrap()
            .last()
            .cloned()
            .unwrap();
        assert_eq!(ui, ("ready".to_string(), String::new()));
        harness.session.stop();
    }

    #[test]
    fn disconnected_session_clears_state() {
        let mut harness = harness(false);
        harness.session.button_down("k4", 7);
        assert!(wait_until(
            || harness.sink.started.load(Ordering::Relaxed) == 1
        ));
        harness.session.send(SessionMessage::Disconnected);

        assert!(wait_until(|| harness
            .sink
            .cancelled
            .load(Ordering::Relaxed)
            == 1));
        assert!(harness
            .sink
            .statuses
            .lock()
            .unwrap()
            .iter()
            .any(|s| s == "设备已断开"));
        // A new press after disconnect must start a fresh session.
        harness.session.button_down("k4", 8);
        assert!(wait_until(
            || harness.sink.started.load(Ordering::Relaxed) == 2
        ));
        harness.session.stop();
    }

    #[test]
    fn external_provider_receives_decoded_pcm() {
        let sink = Arc::new(FakeSink::default());
        let device = Arc::new(FakeDevice::default());
        let factory: Arc<ProviderFactory> = Arc::new(|_config, _sink| Ok(None));
        let config = SessionConfig {
            provider: ProviderChoice::External,
            ..Default::default()
        };
        let mut session = Session::spawn_with(config, sink.clone(), device, factory, timings());

        session.button_down("k4", 1);
        assert!(wait_until(|| sink.started.load(Ordering::Relaxed) == 1));
        session.send(SessionMessage::Audio(audio_frame(1, false)));
        assert!(wait_until(|| !sink.external_pcm.lock().unwrap().is_empty()));

        session.send(SessionMessage::Audio(audio_frame(1, true)));
        session.send(SessionMessage::ExternalText {
            text: "系统识别".into(),
            is_final: true,
        });
        assert!(wait_until(|| !sink.finals.lock().unwrap().is_empty()));
        assert_eq!(sink.finals.lock().unwrap()[0], "系统识别");
        session.stop();
    }

    #[test]
    fn frames_from_another_session_are_ignored() {
        let mut harness = harness(true);
        harness.session.button_down("k4", 7);
        assert!(wait_until(
            || harness.sink.started.load(Ordering::Relaxed) == 1
        ));
        harness
            .session
            .send(SessionMessage::Audio(audio_frame(99, true)));
        thread::sleep(Duration::from_millis(80));
        assert!(harness.sink.finals.lock().unwrap().is_empty());
        assert!(harness.provider.pcm.lock().unwrap().is_empty());
        harness.session.stop();
    }

    #[test]
    fn action_button_reports_to_the_shell() {
        let mut harness = harness(true);
        let mut config = SessionConfig {
            provider: ProviderChoice::StepFun,
            ..Default::default()
        };
        config
            .button_actions
            .insert("k1".into(), ButtonAction::CopyResult);
        harness.session.update_config(config);
        thread::sleep(Duration::from_millis(50));
        harness.session.button_down("k1", 0);

        assert!(wait_until(|| harness
            .sink
            .actions
            .lock()
            .unwrap()
            .iter()
            .any(|a| a == "copyResult")));
        harness.session.stop();
    }
}
