//! Application glue: discovery loop, serial link lifecycle, provisioning and the session
//! state machine.
//!
//! Shells only implement [`SessionSink`] (status/transcript/actions) and [`Credentials`]
//! (Keychain / DPAPI) and start an [`App`].

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::asr::AsrSink;
use crate::auth::DeviceAuthClient;
use crate::discovery::{self, DevicePresence};
use crate::link::{LinkConfig, LinkSink, SerialLink};
use crate::protocol::{AudioFrame, DeviceEvent, DeviceInfo};
use crate::session::{
    DeviceCommands, ProviderChoice, Session, SessionConfig, SessionMessage, SessionSink,
};

// ---------------------------------------------------------------------------
// Shell-provided services
// ---------------------------------------------------------------------------

/// Secret persistence: macOS uses Keychain, Windows uses DPAPI.
pub trait Credentials: Send + Sync + 'static {
    fn load(&self, device_id: &str) -> Option<String>;
    fn save(&self, device_id: &str, secret: &str);
}

/// In-memory credentials, for the CLI and tests.
#[derive(Default)]
pub struct MemoryCredentials {
    secrets: Mutex<std::collections::HashMap<String, String>>,
}

impl Credentials for MemoryCredentials {
    fn load(&self, device_id: &str) -> Option<String> {
        self.secrets.lock().unwrap().get(device_id).cloned()
    }

    fn save(&self, device_id: &str, secret: &str) {
        self.secrets
            .lock()
            .unwrap()
            .insert(device_id.to_string(), secret.to_string());
    }
}

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub session: SessionConfig,
    pub base_url: String,
    pub registration_token: Option<String>,
    /// Delay between device scans while disconnected.
    pub scan_interval: Duration,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            session: SessionConfig::default(),
            base_url: crate::auth::DEFAULT_BASE_URL.to_string(),
            registration_token: None,
            scan_interval: Duration::from_secs(2),
        }
    }
}

// ---------------------------------------------------------------------------
// Link -> app events
// ---------------------------------------------------------------------------

#[derive(Debug)]
enum LinkEvent {
    Audio(AudioFrame),
    Event(DeviceEvent),
    Raw(Vec<u8>),
    Ready(Box<DeviceInfo>),
    Disconnected(String),
    Error(String),
}

struct LinkEvents(Mutex<Sender<Incoming>>);

impl LinkSink for LinkEvents {
    fn on_audio(&self, frame: AudioFrame) {
        self.send(LinkEvent::Audio(frame));
    }

    fn on_event(&self, event: DeviceEvent, _raw: &serde_json::Value) {
        self.send(LinkEvent::Event(event));
    }

    fn on_raw(&self, bytes: &[u8]) {
        self.send(LinkEvent::Raw(bytes.to_vec()));
    }

    fn on_ready(&self, info: &DeviceInfo) {
        self.send(LinkEvent::Ready(Box::new(info.clone())));
    }

    fn on_disconnected(&self, reason: &str) {
        self.send(LinkEvent::Disconnected(reason.to_string()));
    }

    fn on_error(&self, message: &str) {
        self.send(LinkEvent::Error(message.to_string()));
    }
}

impl LinkEvents {
    fn send(&self, event: LinkEvent) {
        if let Ok(tx) = self.0.lock() {
            let _ = tx.send(Incoming::Link(event));
        }
    }
}

enum Incoming {
    Link(LinkEvent),
    Provisioned(Result<Provisioned, String>),
}

struct Provisioned {
    device_id: String,
    secret: String,
    token_ok: bool,
}

enum Control {
    Cancel,
    UpdateConfig(Box<SessionConfig>),
    ExternalText { text: String, is_final: bool },
    Shutdown,
}

/// Forwards device commands to whichever link is currently open.
#[derive(Default)]
struct DeviceBridge {
    link: Mutex<Option<Arc<SerialLink>>>,
}

impl DeviceBridge {
    fn set(&self, link: Option<Arc<SerialLink>>) {
        *self.link.lock().unwrap() = link;
    }
}

impl DeviceCommands for DeviceBridge {
    fn ready(&self, session_id: u64) {
        if let Some(link) = self.link.lock().unwrap().as_ref() {
            link.send_ready(session_id);
        }
    }

    fn ui_state(&self, state: &str, text: &str) {
        if let Some(link) = self.link.lock().unwrap().as_ref() {
            link.send_ui_state(state, text);
        }
    }
}

// ---------------------------------------------------------------------------
// App handle
// ---------------------------------------------------------------------------

pub struct App {
    control: Sender<Control>,
    thread: Option<JoinHandle<()>>,
}

impl App {
    pub fn start(
        config: AppConfig,
        sink: Arc<dyn SessionSink>,
        credentials: Arc<dyn Credentials>,
    ) -> Self {
        Self::start_with_timings(
            config,
            sink,
            credentials,
            crate::session::SessionTimings::default(),
        )
    }

    pub fn start_with_timings(
        config: AppConfig,
        sink: Arc<dyn SessionSink>,
        credentials: Arc<dyn Credentials>,
        timings: crate::session::SessionTimings,
    ) -> Self {
        let (control, control_rx) = mpsc::channel();
        let thread = thread::Builder::new()
            .name("vibeboard-app".into())
            .spawn(move || {
                let mut worker = AppWorker::new(config, sink, credentials, control_rx, timings);
                worker.run();
            })
            .expect("spawn app worker");
        Self {
            control,
            thread: Some(thread),
        }
    }

    pub fn cancel(&self) {
        let _ = self.control.send(Control::Cancel);
    }

    pub fn update_session_config(&self, config: SessionConfig) {
        let _ = self.control.send(Control::UpdateConfig(Box::new(config)));
    }

    /// Delivers a transcript from the shell's own recogniser.
    pub fn external_text(&self, text: String, is_final: bool) {
        let _ = self.control.send(Control::ExternalText { text, is_final });
    }

    pub fn stop(&mut self) {
        let _ = self.control.send(Control::Shutdown);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for App {
    fn drop(&mut self) {
        let _ = self.control.send(Control::Shutdown);
    }
}

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

struct AppWorker {
    config: AppConfig,
    sink: Arc<dyn SessionSink>,
    credentials: Arc<dyn Credentials>,
    control_rx: Receiver<Control>,
    incoming_tx: Sender<Incoming>,
    incoming_rx: Receiver<Incoming>,
    session: Session,
    bridge: Arc<DeviceBridge>,
    link: Option<Arc<SerialLink>>,
    presence: Option<DevicePresence>,
    device_id: Option<String>,
    secret: Option<String>,
    provisioning: bool,
    provisioned_once: bool,
    last_scan: Option<Instant>,
    last_audio: Option<Instant>,
}

impl AppWorker {
    fn new(
        config: AppConfig,
        sink: Arc<dyn SessionSink>,
        credentials: Arc<dyn Credentials>,
        control_rx: Receiver<Control>,
        timings: crate::session::SessionTimings,
    ) -> Self {
        let (incoming_tx, incoming_rx) = mpsc::channel();
        let bridge = Arc::new(DeviceBridge::default());
        let session = Session::spawn_with(
            config.session.clone(),
            Arc::clone(&sink),
            Arc::clone(&bridge) as Arc<dyn DeviceCommands>,
            Arc::new(default_factory),
            timings,
        );
        Self {
            config,
            sink,
            credentials,
            control_rx,
            incoming_tx,
            incoming_rx,
            session,
            bridge,
            link: None,
            presence: None,
            device_id: None,
            secret: None,
            provisioning: false,
            provisioned_once: false,
            last_scan: None,
            last_audio: None,
        }
    }

    fn run(&mut self) {
        self.sink.status("等待设备");
        loop {
            match self.incoming_rx.recv_timeout(Duration::from_millis(100)) {
                Ok(Incoming::Link(event)) => self.handle_link(event),
                Ok(Incoming::Provisioned(result)) => self.handle_provisioned(result),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => break,
            }

            loop {
                match self.control_rx.try_recv() {
                    Ok(Control::Cancel) => self.session.cancel(),
                    Ok(Control::UpdateConfig(config)) => {
                        self.config.session = *config.clone();
                        self.session.update_config(*config);
                    }
                    Ok(Control::ExternalText { text, is_final }) => {
                        self.session
                            .send(SessionMessage::ExternalText { text, is_final });
                    }
                    Ok(Control::Shutdown) | Err(mpsc::TryRecvError::Disconnected) => {
                        self.shutdown();
                        return;
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                }
            }

            self.housekeeping();
        }
        self.shutdown();
    }

    fn shutdown(&mut self) {
        self.session.stop();
        if let Some(link) = self.link.take() {
            link.close();
        }
        self.bridge.set(None);
    }

    fn housekeeping(&mut self) {
        let should_scan = match self.last_scan {
            None => true,
            Some(last) => last.elapsed() >= self.config.scan_interval,
        };
        if self.link.is_none() && should_scan {
            self.last_scan = Some(Instant::now());
            self.open_link();
        }
    }

    fn open_link(&mut self) {
        let presence = match discovery::find_device() {
            Ok(Some(presence)) => presence,
            Ok(None) => return,
            Err(error) => {
                log::warn!("枚举串口失败：{error}");
                return;
            }
        };

        let tx = self.incoming_tx.clone();
        let sink: Arc<dyn LinkSink> = Arc::new(LinkEvents(Mutex::new(tx)));
        match SerialLink::open(LinkConfig::new(presence.port_name.clone()), sink) {
            Ok(link) => {
                log::info!(
                    "设备已连接 port={} serial={:?}",
                    presence.port_name,
                    presence.serial
                );
                self.sink.status("设备已连接");
                let link = Arc::new(link);
                self.bridge.set(Some(Arc::clone(&link)));
                self.link = Some(link);
                self.presence = Some(presence);
                self.provisioning = false;
                self.provisioned_once = false;
            }
            Err(error) => {
                log::warn!("打开串口失败 {}：{error}", presence.port_name);
                self.sink.status("串口连接失败，正在重试");
            }
        }
    }

    fn handle_link(&mut self, event: LinkEvent) {
        match event {
            LinkEvent::Audio(frame) => {
                self.last_audio = Some(Instant::now());
                self.session.send(SessionMessage::Audio(frame));
            }
            LinkEvent::Event(event) => self.handle_device_event(event),
            LinkEvent::Raw(bytes) => match std::str::from_utf8(&bytes) {
                Ok(text) if !text.trim().is_empty() => log::debug!("设备原始输出：{}", text.trim()),
                _ => log::trace!("设备原始数据 {} 字节", bytes.len()),
            },
            LinkEvent::Ready(info) => {
                self.session.send(SessionMessage::Ready(info.clone()));
                self.start_provisioning(&info);
            }
            LinkEvent::Disconnected(reason) => {
                log::warn!("串口断开：{reason}");
                self.session.send(SessionMessage::Disconnected);
                self.bridge.set(None);
                self.link = None;
                self.presence = None;
                self.provisioning = false;
            }
            LinkEvent::Error(message) => {
                log::warn!("链路错误：{message}");
                self.sink.error(&message);
            }
        }
    }

    fn handle_device_event(&mut self, event: DeviceEvent) {
        match event {
            DeviceEvent::ButtonDown { button, session_id } => {
                self.session
                    .send(SessionMessage::ButtonDown { button, session_id });
            }
            DeviceEvent::ButtonUp { button, .. } => {
                self.session.send(SessionMessage::ButtonUp {
                    button,
                    session_id: 0,
                });
            }
            DeviceEvent::ButtonClick { button, .. } => {
                self.session.send(SessionMessage::ButtonClick { button });
            }
            DeviceEvent::ProvisionAck { ok, message } => {
                log::info!("provision_ack ok={ok} message={message:?}");
            }
            DeviceEvent::DeviceInfo(_) => {}
            DeviceEvent::Other(value) => log::debug!("设备事件：{value}"),
        }
    }

    fn start_provisioning(&mut self, info: &DeviceInfo) {
        if self.provisioning {
            return;
        }
        let mac = self
            .presence
            .as_ref()
            .map(|presence| presence.serial.clone())
            .unwrap_or_default();
        if mac.is_empty() {
            log::warn!("设备序列号为空，跳过注册（无法作为 mac 使用）");
            return;
        }
        self.provisioning = true;
        self.provisioned_once = true;

        let hardware = if info.hardware.is_empty() {
            "vibe_keyboard".to_string()
        } else {
            info.hardware.clone()
        };
        let base_url = self.config.base_url.clone();
        let registration_token = self.config.registration_token.clone();
        let credentials = Arc::clone(&self.credentials);
        let tx = self.incoming_tx.clone();

        log::info!("开始注册 mac={mac} hardware={hardware}");
        let _ = thread::Builder::new()
            .name("vibeboard-auth".into())
            .spawn(move || {
                let client = DeviceAuthClient::new(base_url);
                let result = (|| -> Result<Provisioned, String> {
                    let registered = client
                        .register(&mac, &hardware, registration_token.as_deref())
                        .map_err(|error| error.to_string())?;
                    let secret = match registered.secret {
                        Some(secret) => {
                            credentials.save(&registered.device_id, &secret);
                            secret
                        }
                        None => credentials.load(&registered.device_id).ok_or_else(|| {
                            "服务端未返回 device_secret，且本地没有缓存".to_string()
                        })?,
                    };
                    let token_ok = client
                        .valid_token(&registered.device_id, &secret)
                        .map(|_| true)
                        .unwrap_or_else(|error| {
                            log::warn!("token 交换失败：{error}");
                            false
                        });
                    Ok(Provisioned {
                        device_id: registered.device_id,
                        secret,
                        token_ok,
                    })
                })();
                let _ = tx.send(Incoming::Provisioned(result));
            });
    }

    fn handle_provisioned(&mut self, result: Result<Provisioned, String>) {
        self.provisioning = false;
        match result {
            Ok(provisioned) => {
                log::info!(
                    "注册成功 device_id={} token={}",
                    provisioned.device_id,
                    if provisioned.token_ok { "ok" } else { "failed" }
                );
                self.device_id = Some(provisioned.device_id.clone());
                self.secret = Some(provisioned.secret.clone());
                if let Some(link) = &self.link {
                    link.send_provision(&provisioned.device_id, &provisioned.secret);
                }
            }
            Err(message) => {
                log::warn!("注册失败：{message}");
                self.sink.error(&format!("设备注册失败：{message}"));
                // Retry on the next handshake; the link keeps running.
                self.provisioned_once = false;
            }
        }
    }
}

fn default_factory(
    config: &SessionConfig,
    sink: Arc<dyn AsrSink>,
) -> Result<Option<Box<dyn crate::asr::AsrProvider>>, String> {
    crate::session::default_provider(config, Arc::clone(&sink))
}

/// Exposed for shells that want to know whether the app is ready to record.
pub fn provider_is_cloud(choice: ProviderChoice) -> bool {
    choice.is_cloud()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_credentials_round_trip() {
        let credentials = MemoryCredentials::default();
        assert!(credentials.load("dev").is_none());
        credentials.save("dev", "secret");
        assert_eq!(credentials.load("dev").as_deref(), Some("secret"));
    }

    #[test]
    fn device_bridge_without_link_is_a_no_op() {
        let bridge = DeviceBridge::default();
        bridge.ready(3);
        bridge.ui_state("ready", "");
    }

    #[test]
    fn default_config_uses_cloud_stepped_model() {
        let config = AppConfig::default();
        assert_eq!(config.session.provider, ProviderChoice::StepFun);
        assert!(config.session.model.ends_with("-stream"));
    }

    #[test]
    fn protocol_exports_stay_available() {
        // Guards against accidentally dropping the modules the shells rely on.
        let _ = crate::protocol::ping_frame();
    }
}
