//! C ABI used by both shells.
//!
//! Threading contract: every callback runs on a core worker thread. Implementations must
//! copy what they need and marshal to their UI thread; strings are borrowed UTF-8 and only
//! valid for the duration of the call.
//!
//! Ownership: functions returning `*mut c_char` hand over a heap string that must be
//! released with [`vb_string_free`]. Out-parameters named `error` follow the same rule.
//!
//! Panics never cross the boundary: each entry point wraps its body and reports an error.

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex};

use serde::Deserialize;

use crate::app::{App, AppConfig, Credentials};
use crate::asr::LocalStats;
use crate::button::ButtonAction;
use crate::session::{ProviderChoice, SessionConfig, SessionSink};

pub type TextCallback = Option<extern "C" fn(*mut c_void, *const c_char)>;
pub type VoidCallback = Option<extern "C" fn(*mut c_void)>;
pub type PcmCallback = Option<extern "C" fn(*mut c_void, *const u8, usize)>;
pub type LoadSecretCallback = Option<extern "C" fn(*mut c_void, *const c_char) -> *mut c_char>;
pub type SaveSecretCallback = Option<extern "C" fn(*mut c_void, *const c_char, *const c_char)>;
pub type ProgressCallback = Option<extern "C" fn(*mut c_void, u64, u64, i32)>;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct VbCallbacks {
    pub userdata: *mut c_void,
    pub on_status: TextCallback,
    pub on_partial_text: TextCallback,
    pub on_final_text: TextCallback,
    pub on_error: TextCallback,
    pub on_action: TextCallback,
    pub on_local_stats: TextCallback,
    pub on_session_started: VoidCallback,
    pub on_cancelled: VoidCallback,
    pub on_pcm: PcmCallback,
    pub on_pcm_end: VoidCallback,
    pub load_secret: LoadSecretCallback,
    pub save_secret: SaveSecretCallback,
}

impl Default for VbCallbacks {
    fn default() -> Self {
        Self {
            userdata: std::ptr::null_mut(),
            on_status: None,
            on_partial_text: None,
            on_final_text: None,
            on_error: None,
            on_action: None,
            on_local_stats: None,
            on_session_started: None,
            on_cancelled: None,
            on_pcm: None,
            on_pcm_end: None,
            load_secret: None,
            save_secret: None,
        }
    }
}

/// Raw pointer wrapper: the C side guarantees the pointer stays valid while the core runs.
struct CallbackContext {
    callbacks: VbCallbacks,
}

// SAFETY: the shells own `userdata` for the lifetime of the core handle and documented that
// callbacks may run on any core thread.
unsafe impl Send for CallbackContext {}
unsafe impl Sync for CallbackContext {}

impl CallbackContext {
    fn text(&self, callback: TextCallback, value: &str) {
        if let Some(function) = callback {
            if let Ok(text) = CString::new(value) {
                function(self.callbacks.userdata, text.as_ptr());
            }
        }
    }

    fn void(&self, callback: VoidCallback) {
        if let Some(function) = callback {
            function(self.callbacks.userdata);
        }
    }
}

struct FfiSink {
    context: Arc<CallbackContext>,
    last_text: Arc<Mutex<String>>,
}

impl SessionSink for FfiSink {
    fn status(&self, text: &str) {
        self.context.text(self.context.callbacks.on_status, text);
    }

    fn partial_text(&self, text: &str) {
        self.context
            .text(self.context.callbacks.on_partial_text, text);
    }

    fn final_text(&self, text: &str) {
        if let Ok(mut last) = self.last_text.lock() {
            *last = text.to_string();
        }
        self.context
            .text(self.context.callbacks.on_final_text, text);
    }

    fn session_started(&self) {
        self.context.void(self.context.callbacks.on_session_started);
    }

    fn cancelled(&self) {
        self.context.void(self.context.callbacks.on_cancelled);
    }

    fn error(&self, message: &str) {
        self.context.text(self.context.callbacks.on_error, message);
    }

    fn action(&self, action: &str) {
        self.context.text(self.context.callbacks.on_action, action);
    }

    fn local_stats(&self, stats: &LocalStats) {
        let json = serde_json::json!({
            "backend": stats.backend,
            "systemInfo": stats.system_info,
            "model": stats.model,
            "modelSizeMb": stats.model_size_mb,
            "audioSeconds": stats.audio_seconds,
            "durationSeconds": stats.duration_seconds,
            "realtimeFactor": stats.realtime_factor,
            "segments": stats.segments,
            "threads": stats.threads,
            "peakRssMb": stats.peak_rss_mb,
        });
        self.context
            .text(self.context.callbacks.on_local_stats, &json.to_string());
    }

    fn external_pcm(&self, pcm: &[u8]) {
        if let Some(function) = self.context.callbacks.on_pcm {
            function(self.context.callbacks.userdata, pcm.as_ptr(), pcm.len());
        }
    }

    fn external_pcm_end(&self) {
        self.context.void(self.context.callbacks.on_pcm_end);
    }
}

struct FfiCredentials {
    context: Arc<CallbackContext>,
}

impl Credentials for FfiCredentials {
    fn load(&self, device_id: &str) -> Option<String> {
        let function = self.context.callbacks.load_secret?;
        let device = CString::new(device_id).ok()?;
        let pointer = function(self.context.callbacks.userdata, device.as_ptr());
        if pointer.is_null() {
            return None;
        }
        let value = unsafe { CStr::from_ptr(pointer) }
            .to_string_lossy()
            .to_string();
        unsafe { vb_string_free(pointer) };
        (!value.is_empty()).then_some(value)
    }

    fn save(&self, device_id: &str, secret: &str) {
        if let Some(function) = self.context.callbacks.save_secret {
            if let (Ok(device), Ok(secret)) = (CString::new(device_id), CString::new(secret)) {
                function(
                    self.context.callbacks.userdata,
                    device.as_ptr(),
                    secret.as_ptr(),
                );
            }
        }
    }
}

#[derive(Debug, Clone, Deserialize, Default)]
struct ConfigJson {
    provider: Option<String>,
    model: Option<String>,
    whisper_model: Option<String>,
    recognition_key: Option<String>,
    rewrite_enabled: Option<bool>,
    rewrite_model: Option<String>,
    rewrite_key: Option<String>,
    button_actions: Option<HashMap<String, String>>,
    base_url: Option<String>,
    registration_token: Option<String>,
}

fn build_configs(json: &str) -> Result<(SessionConfig, AppConfig), String> {
    let parsed: ConfigJson =
        serde_json::from_str(json).map_err(|error| format!("配置 JSON 无效：{error}"))?;

    let provider = parsed
        .provider
        .as_deref()
        .and_then(ProviderChoice::parse)
        .unwrap_or(ProviderChoice::External);

    let mut session = SessionConfig {
        provider,
        ..Default::default()
    };
    if let Some(model) = parsed.model {
        session.model = model;
    }
    if let Some(model) = parsed.whisper_model {
        session.whisper_model = model;
    }
    if let Some(key) = parsed.recognition_key {
        session.recognition_key = key;
    }
    if let Some(enabled) = parsed.rewrite_enabled {
        session.rewrite_enabled = enabled;
    }
    if let Some(model) = parsed.rewrite_model {
        session.rewrite_model = model;
    }
    if let Some(key) = parsed.rewrite_key {
        session.rewrite_key = key;
    }
    if let Some(actions) = parsed.button_actions {
        session.button_actions = actions
            .into_iter()
            .filter_map(|(button, action)| {
                ButtonAction::parse(&action).map(|action| (button.to_ascii_lowercase(), action))
            })
            .collect();
    }

    let mut app = AppConfig {
        session,
        ..Default::default()
    };
    if let Some(url) = parsed.base_url {
        app.base_url = url;
    }
    app.registration_token = parsed.registration_token;
    Ok((app.session.clone(), app))
}

pub struct VibeBoardHandle {
    state: Mutex<HandleState>,
}

struct HandleState {
    app: Option<App>,
    app_config: AppConfig,
    context: Arc<CallbackContext>,
    last_text: Arc<Mutex<String>>,
}

impl VibeBoardHandle {
    fn new(config_json: &str, callbacks: VbCallbacks) -> Result<Self, String> {
        let (_, app_config) = build_configs(config_json)?;
        let context = Arc::new(CallbackContext { callbacks });
        Ok(Self {
            state: Mutex::new(HandleState {
                app: None,
                app_config,
                context,
                last_text: Arc::new(Mutex::new(String::new())),
            }),
        })
    }
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// # Safety
/// `config_json` must be a valid NUL-terminated UTF-8 string (or null).
#[no_mangle]
pub unsafe extern "C" fn vb_core_new(
    config_json: *const c_char,
    callbacks: VbCallbacks,
    error: *mut *mut c_char,
) -> *mut VibeBoardHandle {
    with_error(error, std::ptr::null_mut(), || {
        let json = if config_json.is_null() {
            "{}".to_string()
        } else {
            CStr::from_ptr(config_json).to_string_lossy().to_string()
        };
        let handle = VibeBoardHandle::new(&json, callbacks)?;
        Ok(Box::into_raw(Box::new(handle)))
    })
}

/// # Safety
/// `handle` must come from [`vb_core_new`] and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn vb_core_free(handle: *mut VibeBoardHandle) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| destroy(handle)));
}

/// Starts the discovery loop. Returns 0 on success, -1 on failure.
///
/// # Safety
/// `handle` must be a valid pointer from [`vb_core_new`].
#[no_mangle]
pub unsafe extern "C" fn vb_core_start(handle: *mut VibeBoardHandle) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let result: Result<Result<(), String>, _> = catch_unwind(AssertUnwindSafe(|| {
        let handle = &*handle;
        let mut state = handle.state.lock().map_err(|_| "句柄已损坏".to_string())?;
        if state.app.is_some() {
            return Ok(());
        }
        let sink: Arc<dyn SessionSink> = Arc::new(FfiSink {
            context: Arc::clone(&state.context),
            last_text: Arc::clone(&state.last_text),
        });
        let credentials: Arc<dyn Credentials> = Arc::new(FfiCredentials {
            context: Arc::clone(&state.context),
        });
        state.app = Some(App::start(state.app_config.clone(), sink, credentials));
        Ok(())
    }));
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(message)) => {
            log::error!("vb_core_start: {message}");
            -1
        }
        Err(_) => -1,
    }
}

/// # Safety
/// `handle` must be a valid pointer from [`vb_core_new`].
#[no_mangle]
pub unsafe extern "C" fn vb_core_stop(handle: *mut VibeBoardHandle) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let handle = &*handle;
        if let Ok(mut state) = handle.state.lock() {
            if let Some(mut app) = state.app.take() {
                app.stop();
            }
        }
    }));
}

/// # Safety
/// `handle` must be a valid pointer from [`vb_core_new`].
#[no_mangle]
pub unsafe extern "C" fn vb_core_cancel(handle: *mut VibeBoardHandle) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Ok(state) = (*handle).state.lock() {
            if let Some(app) = &state.app {
                app.cancel();
            }
        }
    }));
}

/// Replaces the runtime configuration (provider/model/keys/button map) without restarting.
///
/// # Safety
/// `config_json` must be NUL-terminated UTF-8; `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn vb_core_update_config(
    handle: *mut VibeBoardHandle,
    config_json: *const c_char,
    error: *mut *mut c_char,
) -> i32 {
    with_error(error, -1, || {
        if handle.is_null() || config_json.is_null() {
            return Err("参数为空".to_string());
        }
        let json = CStr::from_ptr(config_json).to_string_lossy().to_string();
        let (_, app_config) = build_configs(&json)?;
        let handle = &*handle;
        let mut state = handle.state.lock().map_err(|_| "句柄已损坏".to_string())?;
        state.app_config = app_config;
        if let Some(app) = &state.app {
            app.update_session_config(state.app_config.session.clone());
        }
        Ok(0)
    })
}

/// Feeds a transcript produced by the shell's own recogniser (Apple Speech /
/// System.Speech) back into the session, which then drives the device screen and output.
///
/// # Safety
/// `handle` must be valid; `text` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn vb_core_external_text(
    handle: *mut VibeBoardHandle,
    text: *const c_char,
    is_final: i32,
) {
    if handle.is_null() || text.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let value = CStr::from_ptr(text).to_string_lossy().to_string();
        if let Ok(state) = (*handle).state.lock() {
            // The session queue is reached through a fresh cancel-free path: App owns the
            // session, so we route via the app's update channel.
            if let Some(app) = &state.app {
                app.external_text(value, is_final != 0);
            }
        }
    }));
}

/// Latest final transcript, or null when nothing has been recognised yet.
///
/// # Safety
/// `handle` must be a valid pointer from [`vb_core_new`]. Free the result with
/// [`vb_string_free`].
#[no_mangle]
pub unsafe extern "C" fn vb_core_last_text(handle: *mut VibeBoardHandle) -> *mut c_char {
    if handle.is_null() {
        return std::ptr::null_mut();
    }
    let value = catch_unwind(AssertUnwindSafe(|| {
        let handle = &*handle;
        let state = handle.state.lock().ok()?;
        let text = state.last_text.lock().ok()?.clone();
        Some(text)
    }));
    match value {
        Ok(Some(text)) if !text.is_empty() => to_c_string(&text),
        _ => std::ptr::null_mut(),
    }
}

/// Allocates a string that the core frees with [`vb_string_free`]. Shells use this for
/// `load_secret` return values.
///
/// # Safety
/// `utf8` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn vb_string_alloc(utf8: *const c_char) -> *mut c_char {
    if utf8.is_null() {
        return std::ptr::null_mut();
    }
    to_c_string(&CStr::from_ptr(utf8).to_string_lossy())
}

/// Frees any string returned by this library.
///
/// # Safety
/// `value` must originate from this library and be freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn vb_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

/// JSON describing the local recognition build: `{active, compiled[], systemInfo}`.
/// Returns null when the `whisper` feature is disabled.
#[no_mangle]
pub extern "C" fn vb_local_backend_info() -> *mut c_char {
    local_backend_json()
}

#[cfg(feature = "whisper")]
fn local_backend_json() -> *mut c_char {
    let info = crate::asr::whisper::backend_info();
    let json = serde_json::json!({
        "active": info.active,
        "compiled": info.compiled,
        "systemInfo": info.system_info,
    });
    to_c_string(&json.to_string())
}

#[cfg(not(feature = "whisper"))]
fn local_backend_json() -> *mut c_char {
    std::ptr::null_mut()
}

/// Model catalogue as JSON: `[{name,fileName,sizeMb,quality}]`.
#[no_mangle]
pub extern "C" fn vb_model_catalog() -> *mut c_char {
    let models: Vec<serde_json::Value> = crate::models::MODELS
        .iter()
        .map(|spec| {
            serde_json::json!({
                "name": spec.name,
                "fileName": spec.file_name,
                "sizeMb": spec.size_mb,
                "quality": spec.quality,
                "installed": crate::models::path_for(spec.name).is_file(),
                "path": crate::models::path_for(spec.name).to_string_lossy(),
            })
        })
        .collect();
    to_c_string(&serde_json::Value::Array(models).to_string())
}

/// Downloads a model synchronously, reporting `(received, total, hasTotal)`.
/// Returns 0 on success, -1 on failure.
///
/// # Safety
/// `name` must be NUL-terminated UTF-8; `error` may be null.
#[no_mangle]
pub unsafe extern "C" fn vb_download_model(
    name: *const c_char,
    callback: ProgressCallback,
    userdata: *mut c_void,
    error: *mut *mut c_char,
) -> i32 {
    if name.is_null() {
        if !error.is_null() {
            *error = to_c_string("模型名为空");
        }
        return -1;
    }
    let name = CStr::from_ptr(name).to_string_lossy().to_string();
    let result = catch_unwind(AssertUnwindSafe(|| {
        crate::models::ensure(&name, |progress| {
            if let Some(function) = callback {
                function(
                    userdata,
                    progress.received,
                    progress.total.unwrap_or(0),
                    progress.total.is_some() as i32,
                );
            }
        })
        .map(|_| ())
    }));
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(message)) => {
            if !error.is_null() {
                *error = to_c_string(&message);
            }
            -1
        }
        Err(_) => {
            if !error.is_null() {
                *error = to_c_string("下载时发生内部错误");
            }
            -1
        }
    }
}

/// True when the named model (or path) is present on disk.
///
/// # Safety
/// `name` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn vb_model_available(name: *const c_char) -> i32 {
    if name.is_null() {
        return 0;
    }
    let name = CStr::from_ptr(name).to_string_lossy().to_string();
    crate::models::is_available(&name) as i32
}

/// Removes a downloaded model. Returns 0 on success.
///
/// # Safety
/// `name` must be NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn vb_model_remove(name: *const c_char, error: *mut *mut c_char) -> i32 {
    if name.is_null() {
        return -1;
    }
    let name = CStr::from_ptr(name).to_string_lossy().to_string();
    match crate::models::remove(&name) {
        Ok(()) => 0,
        Err(message) => {
            if !error.is_null() {
                *error = to_c_string(&message);
            }
            -1
        }
    }
}

/// Log sinks are called from arbitrary core threads; the shell guarantees pointer validity.
struct LogSink {
    callback: extern "C" fn(*mut c_void, *const c_char),
    userdata: *mut c_void,
}

unsafe impl Send for LogSink {}

static LOG_SINK: Mutex<Option<LogSink>> = Mutex::new(None);

struct FfiLogger;

impl log::Log for FfiLogger {
    fn enabled(&self, _metadata: &log::Metadata) -> bool {
        true
    }

    fn log(&self, record: &log::Record) {
        let Ok(sink) = LOG_SINK.lock() else { return };
        let Some(sink) = sink.as_ref() else { return };
        let line = format!(
            "[{}] {}: {}",
            record.level().as_str().to_lowercase(),
            record.target(),
            record.args()
        );
        if let Ok(text) = CString::new(line) {
            (sink.callback)(sink.userdata, text.as_ptr());
        }
    }

    fn flush(&self) {}
}

/// Routes core logs to the shell so they land in the same file as UI logs.
/// Safe to call more than once; later calls replace the sink.
///
/// # Safety
/// `userdata` must stay valid for as long as the core runs.
#[no_mangle]
pub extern "C" fn vb_set_log_callback(
    callback: Option<extern "C" fn(*mut c_void, *const c_char)>,
    userdata: *mut c_void,
) {
    if let Ok(mut sink) = LOG_SINK.lock() {
        *sink = callback.map(|callback| LogSink { callback, userdata });
    }
    static INSTALL: std::sync::Once = std::sync::Once::new();
    INSTALL.call_once(|| {
        let _ = log::set_boxed_logger(Box::new(FfiLogger));
        log::set_max_level(log::LevelFilter::Info);
    });
}

/// Library version string. Free with [`vb_string_free`].
#[no_mangle]
pub extern "C" fn vb_version() -> *mut c_char {
    to_c_string(env!("CARGO_PKG_VERSION"))
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Takes the app out of the handle, releases the box, then stops the app (which joins
/// worker threads) so the destroy path never holds the lock across a join.
fn destroy(handle: *mut VibeBoardHandle) {
    let boxed = unsafe { Box::from_raw(handle) };
    let app = match boxed.state.lock() {
        Ok(mut state) => state.app.take(),
        Err(poisoned) => poisoned.into_inner().app.take(),
    };
    drop(boxed);
    if let Some(mut app) = app {
        app.stop();
    }
}

fn to_c_string(value: &str) -> *mut c_char {
    match CString::new(value) {
        Ok(text) => text.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

fn with_error<T>(
    error: *mut *mut c_char,
    fallback: T,
    body: impl FnOnce() -> Result<T, String>,
) -> T {
    let outcome = catch_unwind(AssertUnwindSafe(body));
    match outcome {
        Ok(Ok(value)) => value,
        Ok(Err(message)) => {
            log::error!("ffi error: {message}");
            if !error.is_null() {
                unsafe { *error = to_c_string(&message) };
            }
            fallback
        }
        Err(_) => {
            log::error!("ffi panic");
            if !error.is_null() {
                unsafe { *error = to_c_string("内核内部错误") };
            }
            fallback
        }
    }
}

/// Test-only helper: run one external-provider session without hardware.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_json_maps_to_session_and_app() {
        let (session, app) = build_configs(
            r#"{
                "provider": "whisper",
                "whisper_model": "base",
                "button_actions": {"k1": "copyResult", "k2": "bogus"},
                "rewrite_enabled": true,
                "rewrite_key": "rk"
            }"#,
        )
        .unwrap();
        assert_eq!(session.provider, ProviderChoice::Whisper);
        assert_eq!(session.whisper_model, "base");
        assert_eq!(
            session.button_actions.get("k1"),
            Some(&ButtonAction::CopyResult)
        );
        assert!(!session.button_actions.contains_key("k2"));
        assert!(session.rewrite_enabled);
        assert_eq!(session.rewrite_key, "rk");
        assert_eq!(app.session.provider, ProviderChoice::Whisper);
    }

    #[test]
    fn invalid_json_is_rejected() {
        assert!(build_configs("{not json").is_err());
    }

    #[test]
    fn missing_provider_defaults_to_external() {
        let (session, _) = build_configs("{}").unwrap();
        assert_eq!(session.provider, ProviderChoice::External);
    }

    #[test]
    fn handle_lifecycle_is_safe_without_start() {
        unsafe {
            let handle = vb_core_new(
                std::ptr::null(),
                VbCallbacks::default(),
                std::ptr::null_mut(),
            );
            assert!(!handle.is_null());
            assert_eq!(vb_core_last_text(handle), std::ptr::null_mut());
            vb_core_cancel(handle);
            vb_core_stop(handle);
            vb_core_free(handle);
        }
    }

    #[test]
    fn strings_round_trip() {
        unsafe {
            let pointer = vb_version();
            assert!(!pointer.is_null());
            assert_eq!(
                CStr::from_ptr(pointer).to_str().unwrap(),
                env!("CARGO_PKG_VERSION")
            );
            vb_string_free(pointer);
        }
    }

    #[test]
    fn model_catalog_is_json_array() {
        unsafe {
            let pointer = vb_model_catalog();
            let text = CStr::from_ptr(pointer).to_str().unwrap().to_string();
            vb_string_free(pointer);
            let value: serde_json::Value = serde_json::from_str(&text).unwrap();
            assert!(value.as_array().unwrap().len() >= 3);
        }
    }

    #[test]
    fn errors_are_reported_through_out_params() {
        let mut error: *mut c_char = std::ptr::null_mut();
        let handle = unsafe {
            vb_core_new(
                CString::new("{broken").unwrap().as_ptr(),
                VbCallbacks::default(),
                &mut error,
            )
        };
        assert!(handle.is_null());
        assert!(!error.is_null());
        unsafe { vb_string_free(error) };
    }

    // Guards against accidentally changing the ABI shape the shells depend on.
    #[test]
    fn callbacks_struct_is_repr_c() {
        assert_eq!(
            std::mem::size_of::<VbCallbacks>(),
            std::mem::size_of::<*mut c_void>()
                + 12 * std::mem::size_of::<Option<extern "C" fn()>>()
        );
    }

    #[test]
    fn local_stats_default_is_empty() {
        let stats = LocalStats::default();
        assert!(stats.backend.is_empty());
        assert_eq!(stats.segments, 0);
    }
}
