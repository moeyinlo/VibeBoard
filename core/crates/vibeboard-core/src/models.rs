//! Local Whisper model management.
//!
//! Models are downloaded on demand (they are far too large to ship with the app) into a
//! per-user directory, so both shells and the CLI can share one copy:
//!
//! - macOS: `~/Library/Application Support/VibeBoardPlus/models`
//! - Windows: `%LOCALAPPDATA%\VibeBoardPlus\models`
//! - Linux: `$XDG_DATA_HOME/VibeBoardPlus/models`

use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModelSpec {
    pub name: &'static str,
    pub file_name: &'static str,
    /// Path inside the whisper.cpp model repository.
    pub repo_path: &'static str,
    /// Approximate download size, for UI labels.
    pub size_mb: u64,
    /// Rough Chinese quality hint shown in settings.
    pub quality: &'static str,
}

pub const MODELS: &[ModelSpec] = &[
    ModelSpec {
        name: "tiny",
        file_name: "ggml-tiny.bin",
        repo_path: "ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin",
        size_mb: 75,
        quality: "最快，中文准确率低",
    },
    ModelSpec {
        name: "base",
        file_name: "ggml-base.bin",
        repo_path: "ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
        size_mb: 142,
        quality: "较快，中文一般",
    },
    ModelSpec {
        name: "small",
        file_name: "ggml-small.bin",
        repo_path: "ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
        size_mb: 466,
        quality: "推荐，中文可用",
    },
    ModelSpec {
        name: "medium",
        file_name: "ggml-medium.bin",
        repo_path: "ggerganov/whisper.cpp/resolve/main/ggml-medium.bin",
        size_mb: 1500,
        quality: "更准，明显更慢",
    },
    ModelSpec {
        name: "large-v3-turbo",
        file_name: "ggml-large-v3-turbo.bin",
        repo_path: "ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
        size_mb: 1620,
        quality: "最准（turbo 版比 large 快数倍），内存占用约 2 GB",
    },
];

pub fn spec(name: &str) -> Option<&'static ModelSpec> {
    MODELS
        .iter()
        .find(|model| model.name.eq_ignore_ascii_case(name))
}

pub fn base_dir() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_default();
        home.join("Library/Application Support/VibeBoardPlus")
    }
    #[cfg(windows)]
    {
        std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
            .join("VibeBoardPlus")
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share"))
            })
            .unwrap_or_else(std::env::temp_dir)
            .join("VibeBoardPlus")
    }
}

pub fn models_dir() -> PathBuf {
    base_dir().join("models")
}

/// Resolves a user setting into a concrete model file.
///
/// Accepts a known model name (`base`), an explicit path, or an empty value (defaults to
/// `small`). Returns `None` when the resolved file does not exist yet.
pub fn resolve(name: &str) -> Option<PathBuf> {
    let trimmed = name.trim();
    let candidate = if trimmed.is_empty() {
        models_dir().join("ggml-small.bin")
    } else if let Some(spec) = spec(trimmed) {
        models_dir().join(spec.file_name)
    } else {
        PathBuf::from(trimmed)
    };
    candidate.is_file().then_some(candidate)
}

pub fn path_for(model: &str) -> PathBuf {
    let trimmed = model.trim();
    if trimmed.is_empty() {
        return models_dir().join("ggml-small.bin");
    }
    match spec(trimmed) {
        Some(spec) => models_dir().join(spec.file_name),
        None => PathBuf::from(trimmed),
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Progress {
    pub received: u64,
    pub total: Option<u64>,
}

impl Progress {
    pub fn fraction(&self) -> Option<f32> {
        self.total
            .filter(|total| *total > 0)
            .map(|total| (self.received as f32 / total as f32).clamp(0.0, 1.0))
    }

    pub fn megabytes(&self) -> f32 {
        self.received as f32 / (1024.0 * 1024.0)
    }
}

/// Download hosts, tried in order. Chinese networks usually reach the mirror but not
/// huggingface.co; set `VIBEBOARD_MODEL_MIRROR` to override with a comma-separated list.
pub fn hosts() -> Vec<String> {
    if let Ok(custom) = std::env::var("VIBEBOARD_MODEL_MIRROR") {
        let hosts: Vec<String> = custom
            .split(',')
            .map(|host| host.trim().trim_end_matches('/').to_string())
            .filter(|host| !host.is_empty())
            .collect();
        if !hosts.is_empty() {
            return hosts;
        }
    }
    vec![
        "https://hf-mirror.com".to_string(),
        "https://huggingface.co".to_string(),
    ]
}

pub fn urls_for(spec: &ModelSpec) -> Vec<String> {
    hosts()
        .into_iter()
        .map(|host| format!("{host}/{}", spec.repo_path.trim_start_matches('/')))
        .collect()
}

/// Downloads a model (if absent) and returns its path. Downloads to a `.part` file first so
/// an interrupted transfer never looks like a valid model.
pub fn ensure(model: &str, mut progress: impl FnMut(Progress)) -> Result<PathBuf, String> {
    let spec =
        spec(model).ok_or_else(|| format!("未知模型：{model}（可选 tiny/base/small/medium）"))?;
    let dir = models_dir();
    fs::create_dir_all(&dir).map_err(|e| format!("无法创建模型目录 {}：{e}", dir.display()))?;
    let target = dir.join(spec.file_name);
    if target.is_file() {
        return Ok(target);
    }

    let part = dir.join(format!("{}.part", spec.file_name));
    let _ = fs::remove_file(&part);

    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(15))
        .timeout(Duration::from_secs(600))
        .build();

    let mut last_error = String::new();
    let mut response = None;
    for url in urls_for(spec) {
        log::info!("下载模型 {}（约 {} MB）：{url}", spec.name, spec.size_mb);
        match agent.get(&url).call() {
            Ok(candidate) => {
                response = Some(candidate);
                break;
            }
            Err(error) => {
                log::warn!("下载源不可用：{url}（{error}）");
                last_error = format!("{url}: {error}");
            }
        }
    }
    let response = response.ok_or_else(|| {
        format!(
            "下载失败（{}）：所有下载源都不可用（{last_error}）。\n可设置 VIBEBOARD_MODEL_MIRROR 指定镜像后再试。",
            spec.name
        )
    })?;
    let total = response
        .header("Content-Length")
        .and_then(|value| value.parse::<u64>().ok());

    let mut reader = response.into_reader();
    let mut file = File::create(&part).map_err(|e| format!("无法写入 {}：{e}", part.display()))?;
    let mut buffer = [0u8; 128 * 1024];
    let mut received: u64 = 0;
    let mut last_report = Instant::now();
    let mut last_bytes: u64 = 0;

    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|e| format!("下载中断：{e}"))?;
        if read == 0 {
            break;
        }
        file.write_all(&buffer[..read])
            .map_err(|e| format!("写入失败：{e}"))?;
        received += read as u64;
        if last_report.elapsed() >= Duration::from_millis(200) {
            last_report = Instant::now();
            let _ = last_bytes;
            last_bytes = received;
            progress(Progress { received, total });
        }
    }
    file.sync_all().map_err(|e| format!("写入失败：{e}"))?;
    drop(file);

    if received == 0 {
        let _ = fs::remove_file(&part);
        return Err("下载失败：文件为空".into());
    }
    fs::rename(&part, &target).map_err(|e| format!("无法保存模型：{e}"))?;
    progress(Progress {
        received,
        total: total.or(Some(received)),
    });
    log::info!("模型就绪：{}", target.display());
    Ok(target)
}

/// Best-effort download of the default model when nothing is installed yet.
pub fn ensure_default(progress: impl FnMut(Progress)) -> Result<PathBuf, String> {
    ensure("small", progress)
}

pub fn is_available(model: &str) -> bool {
    resolve(model).is_some()
}

/// Removes a downloaded model; used by the settings UI.
pub fn remove(model: &str) -> Result<(), String> {
    let path = path_for(model);
    if path.is_file() {
        fs::remove_file(&path).map_err(|e| format!("删除失败：{e}"))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_models_resolve() {
        assert_eq!(spec("BASE").map(|s| s.name), Some("base"));
        assert!(spec("nope").is_none());
    }

    #[test]
    fn explicit_paths_are_preserved() {
        assert_eq!(
            path_for("/tmp/custom.bin"),
            PathBuf::from("/tmp/custom.bin")
        );
        assert!(path_for("base").ends_with("ggml-base.bin"));
    }

    #[test]
    fn missing_model_is_reported_as_unavailable() {
        assert!(!is_available("/definitely/missing/model.bin"));
    }

    #[test]
    fn progress_fraction_is_bounded() {
        assert_eq!(
            Progress {
                received: 50,
                total: Some(100)
            }
            .fraction(),
            Some(0.5)
        );
        assert_eq!(
            Progress {
                received: 150,
                total: Some(100)
            }
            .fraction(),
            Some(1.0)
        );
        assert_eq!(
            Progress {
                received: 5,
                total: None
            }
            .fraction(),
            None
        );
    }

    #[test]
    fn models_dir_is_per_user() {
        let dir = models_dir();
        assert!(dir.ends_with("models"));
        assert!(dir.to_string_lossy().contains("VibeBoardPlus"));
    }
}
