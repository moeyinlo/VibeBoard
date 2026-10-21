//! Local, offline recognition with whisper.cpp (`whisper-rs`).
//!
//! Audio is buffered for the whole session and transcribed on release; the model is loaded
//! per session with mmap so repeated use stays fast. Requires the `whisper` feature.
//!
//! Acceleration is a compile-time choice (whisper.cpp has no runtime backend switching):
//! - `--features whisper-metal`  (macOS)
//! - `--features whisper-cuda`   (Windows/Linux + CUDA toolkit)
//! - `--features whisper-vulkan` / `whisper-coreml`
//!
//! The active backend and whisper.cpp's device report are exposed through [`backend_info`]
//! and attached to every [`LocalStats`] so the shells can show what is actually running.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Instant;

use super::{AsrProvider, AsrSink, LocalStats};

/// Whisper expects 16 kHz mono float samples in [-1, 1].
fn pcm16_to_f32(pcm: &[u8]) -> Vec<f32> {
    pcm.chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]) as f32 / 32768.0)
        .collect()
}

#[derive(Debug, Clone)]
pub struct BackendInfo {
    /// Backend whisper.cpp will use for this build.
    pub active: &'static str,
    /// Every backend compiled into this build.
    pub compiled: Vec<&'static str>,
    /// whisper.cpp's own report: device names, SIMD flags, memory.
    pub system_info: &'static str,
}

/// Routes whisper.cpp/ggml output through `log` (stdout otherwise). Idempotent.
fn ensure_logging_hooks() {
    static HOOKS: std::sync::Once = std::sync::Once::new();
    HOOKS.call_once(whisper_rs::install_logging_hooks);
}

pub fn backend_info() -> BackendInfo {
    ensure_logging_hooks();
    let mut compiled = vec!["CPU"];
    if cfg!(feature = "whisper-cuda") {
        compiled.push("CUDA");
    }
    if cfg!(feature = "whisper-metal") {
        compiled.push("Metal");
    }
    if cfg!(feature = "whisper-vulkan") {
        compiled.push("Vulkan");
    }
    if cfg!(feature = "whisper-coreml") {
        compiled.push("CoreML");
    }
    let active = if cfg!(feature = "whisper-cuda") {
        "CUDA"
    } else if cfg!(feature = "whisper-metal") {
        "Metal"
    } else if cfg!(feature = "whisper-vulkan") {
        "Vulkan"
    } else if cfg!(feature = "whisper-coreml") {
        "CoreML"
    } else {
        "CPU"
    };
    BackendInfo {
        active,
        compiled,
        system_info: whisper_rs::print_system_info(),
    }
}

/// Peak resident set size of this process, in MiB.
#[cfg(unix)]
pub fn peak_rss_mb() -> Option<f64> {
    unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        if libc::getrusage(libc::RUSAGE_SELF, &mut usage) == 0 {
            // macOS reports bytes, Linux kilobytes.
            let bytes = if cfg!(target_os = "macos") {
                usage.ru_maxrss as f64
            } else {
                usage.ru_maxrss as f64 * 1024.0
            };
            return Some(bytes / (1024.0 * 1024.0));
        }
    }
    None
}

#[cfg(windows)]
pub fn peak_rss_mb() -> Option<f64> {
    use windows_sys::Win32::System::ProcessStatus::{
        GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS,
    };
    use windows_sys::Win32::System::Threading::GetCurrentProcess;
    unsafe {
        let mut counters: PROCESS_MEMORY_COUNTERS = std::mem::zeroed();
        counters.cb = std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32;
        if GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, counters.cb) != 0 {
            Some(counters.PeakWorkingSetSize as f64 / (1024.0 * 1024.0))
        } else {
            None
        }
    }
}

#[cfg(not(any(unix, windows)))]
pub fn peak_rss_mb() -> Option<f64> {
    None
}

pub struct WhisperAsr {
    model: PathBuf,
    language: String,
    sink: Arc<dyn AsrSink>,
    pcm: Vec<u8>,
    cancelled: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
}

impl WhisperAsr {
    pub fn new(model: PathBuf, sink: Arc<dyn AsrSink>) -> Self {
        Self {
            model,
            language: "zh".into(),
            sink,
            pcm: Vec::new(),
            cancelled: Arc::new(AtomicBool::new(false)),
            worker: None,
        }
    }

    pub fn with_language(mut self, language: impl Into<String>) -> Self {
        self.language = language.into();
        self
    }
}

impl AsrProvider for WhisperAsr {
    fn name(&self) -> &'static str {
        "whisper"
    }

    fn start(&mut self) -> Result<(), String> {
        if !self.model.is_file() {
            return Err(format!(
                "本地模型不存在：{}。请在设置中下载模型（或运行 vibeboard --download-model small）",
                self.model.display()
            ));
        }
        self.pcm.clear();
        self.cancelled.store(false, Ordering::SeqCst);
        let info = backend_info();
        log::info!(
            "本地 Whisper 会话开始 model={} backend={} compiled={:?}",
            self.model.display(),
            info.active,
            info.compiled
        );
        Ok(())
    }

    fn send_pcm(&mut self, pcm16: &[u8]) {
        self.pcm.extend_from_slice(pcm16);
        if self.pcm.len() > 16_000 * 2 * 300 {
            self.pcm.clear();
            self.sink.on_error("本地识别单次最多 5 分钟，请分段录制");
        }
    }

    fn finish(&mut self) {
        let pcm = std::mem::take(&mut self.pcm);
        if pcm.len() < 16_000 / 2 {
            self.sink.on_error("录音太短，未识别到文字");
            return;
        }
        let model = self.model.clone();
        let language = self.language.clone();
        let sink = Arc::clone(&self.sink);
        let cancelled = Arc::clone(&self.cancelled);

        self.worker = Some(
            thread::Builder::new()
                .name("vibeboard-whisper".into())
                .spawn(
                    move || match transcribe(&model, &language, &pcm, &cancelled) {
                        Ok((text, stats)) => {
                            sink.on_stats(&stats);
                            sink.on_text(&text, true);
                        }
                        Err(message) => sink.on_error(&message),
                    },
                )
                .expect("spawn whisper worker"),
        );
    }

    fn stop(&mut self) {
        self.cancelled.store(true, Ordering::SeqCst);
        self.pcm.clear();
        if let Some(worker) = self.worker.take() {
            drop(worker);
        }
    }
}

impl Drop for WhisperAsr {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }
}

pub fn transcribe_pcm(
    model: &std::path::Path,
    language: &str,
    pcm16: &[u8],
) -> Result<(String, LocalStats), String> {
    transcribe(
        &model.to_path_buf(),
        language,
        pcm16,
        &AtomicBool::new(false),
    )
}

fn transcribe(
    model: &PathBuf,
    language: &str,
    pcm16: &[u8],
    cancelled: &AtomicBool,
) -> Result<(String, LocalStats), String> {
    use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

    let audio_seconds = pcm16.len() as f64 / 2.0 / 16_000.0;
    let samples = pcm16_to_f32(pcm16);
    if cancelled.load(Ordering::Relaxed) {
        return Ok((String::new(), LocalStats::default()));
    }

    let backend = backend_info();
    let started = Instant::now();

    let context = WhisperContext::new_with_params(
        model.to_str().ok_or("模型路径不是有效 UTF-8")?,
        WhisperContextParameters::default(),
    )
    .map_err(|error| format!("加载本地模型失败：{error}"))?;

    let mut state = context
        .create_state()
        .map_err(|error| format!("初始化识别失败：{error}"))?;

    let threads = std::thread::available_parallelism()
        .map(|value| value.get().min(8) as i32)
        .unwrap_or(4);

    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_n_threads(threads);
    params.set_translate(false);
    params.set_language(Some(language));
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    params.set_suppress_blank(true);
    // Music/symbol tokens are a common source of hallucinated Chinese output.
    params.set_suppress_nst(true);
    params.set_debug_mode(false);
    // Bias towards Simplified Chinese with punctuation; whisper otherwise drifts to
    // Traditional characters and drops punctuation on short clips.
    params.set_initial_prompt("以下是普通话的句子，使用简体中文和标准标点符号。");

    state
        .full(params, &samples)
        .map_err(|error| format!("本地识别失败：{error}"))?;

    let segments = state.full_n_segments();
    let mut text = String::new();
    for index in 0..segments {
        if cancelled.load(Ordering::Relaxed) {
            return Ok((String::new(), LocalStats::default()));
        }
        if let Some(segment) = state.get_segment(index) {
            if let Ok(chunk) = segment.to_str() {
                text.push_str(chunk.trim());
            }
        }
    }

    let duration_seconds = started.elapsed().as_secs_f64();
    let stats = LocalStats {
        backend: backend.active.to_string(),
        system_info: backend.system_info.to_string(),
        model: model
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_default(),
        model_size_mb: std::fs::metadata(model)
            .map(|m| m.len() as f64 / (1024.0 * 1024.0))
            .unwrap_or(0.0),
        audio_seconds,
        duration_seconds,
        realtime_factor: if audio_seconds > 0.0 {
            duration_seconds / audio_seconds
        } else {
            0.0
        },
        segments: segments.max(0) as usize,
        threads,
        peak_rss_mb: peak_rss_mb(),
    };

    log::info!(
        "本地识别完成：{} 字符，耗时 {:.2}s（音频 {:.2}s, RTF {:.2}, {}）",
        text.trim().chars().count(),
        duration_seconds,
        audio_seconds,
        stats.realtime_factor,
        stats.backend
    );
    Ok((text.trim().to_string(), stats))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[derive(Default)]
    struct RecordingSink {
        text: Mutex<Vec<(String, bool)>>,
        errors: Mutex<Vec<String>>,
        stats: Mutex<Vec<LocalStats>>,
    }

    impl AsrSink for RecordingSink {
        fn on_text(&self, text: &str, is_final: bool) {
            self.text.lock().unwrap().push((text.to_string(), is_final));
        }
        fn on_error(&self, message: &str) {
            self.errors.lock().unwrap().push(message.to_string());
        }
        fn on_stats(&self, stats: &LocalStats) {
            self.stats.lock().unwrap().push(stats.clone());
        }
    }

    #[test]
    fn pcm_conversion_preserves_range() {
        let samples = pcm16_to_f32(&[0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80]);
        assert_eq!(samples.len(), 3);
        assert!((samples[0] - 0.0).abs() < f32::EPSILON);
        assert!((samples[1] - 0.9999).abs() < 0.001);
        assert!((samples[2] + 1.0).abs() < 0.001);
    }

    #[test]
    fn missing_model_is_rejected_at_start() {
        let recording = Arc::new(RecordingSink::default());
        let sink: Arc<dyn AsrSink> = recording;
        let mut provider = WhisperAsr::new(PathBuf::from("/definitely/missing.bin"), sink);
        let error = provider.start().unwrap_err();
        assert!(error.contains("本地模型不存在"));
    }

    #[test]
    fn short_audio_reports_instead_of_running_the_model() {
        let recording = Arc::new(RecordingSink::default());
        let sink: Arc<dyn AsrSink> = recording.clone();
        // Point at any existing file: finish() checks length before loading the model.
        let model = std::env::current_exe().unwrap();
        let mut provider = WhisperAsr::new(model, sink);
        provider.send_pcm(&[0u8; 100]);
        provider.finish();
        assert_eq!(recording.errors.lock().unwrap().len(), 1);
        assert!(recording.errors.lock().unwrap()[0].contains("太短"));
    }

    #[test]
    fn backend_info_reports_the_build() {
        let info = backend_info();
        assert!(info.compiled.contains(&"CPU"));
        assert!(
            !info.system_info.is_empty(),
            "whisper.cpp always prints a system report"
        );
        let expected = if cfg!(feature = "whisper-cuda") {
            "CUDA"
        } else if cfg!(feature = "whisper-metal") {
            "Metal"
        } else {
            "CPU"
        };
        if !cfg!(any(feature = "whisper-vulkan", feature = "whisper-coreml")) {
            assert_eq!(info.active, expected);
        }
    }

    #[test]
    fn peak_memory_is_reported() {
        let memory = peak_rss_mb();
        #[cfg(any(unix, windows))]
        assert!(memory.unwrap_or(0.0) > 0.0);
        #[cfg(not(any(unix, windows)))]
        assert!(memory.is_none());
    }

    #[test]
    fn stats_summary_mentions_backend_and_rtf() {
        let stats = LocalStats {
            backend: "Metal".into(),
            model: "ggml-small.bin".into(),
            audio_seconds: 2.0,
            duration_seconds: 1.0,
            realtime_factor: 0.5,
            threads: 8,
            peak_rss_mb: Some(512.0),
            ..Default::default()
        };
        let summary = stats.summary();
        assert!(summary.contains("Metal"));
        assert!(summary.contains("RTF 0.50"));
        assert!(summary.contains("512 MB"));
    }
}
