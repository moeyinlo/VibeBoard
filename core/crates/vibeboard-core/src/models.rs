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
        quality: "旧版推荐，中文一般",
    },
    ModelSpec {
        name: "small-q5_1",
        file_name: "ggml-small-q5_1.bin",
        repo_path: "ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin",
        size_mb: 181,
        quality: "small 的 5bit 量化：更小更快，质量接近 small",
    },
    ModelSpec {
        name: "medium-q5_0",
        file_name: "ggml-medium-q5_0.bin",
        repo_path: "ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin",
        size_mb: 514,
        quality: "medium 量化版，中文好但偏慢",
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
        size_mb: 1549,
        quality: "最准（turbo 比 large 快数倍），内存约 2 GB",
    },
    ModelSpec {
        name: "large-v3-turbo-q5_0",
        file_name: "ggml-large-v3-turbo-q5_0.bin",
        repo_path: "ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
        size_mb: 547,
        quality: "推荐：turbo 的 5bit 量化，体积接近 small，中文明显更准",
    },
    ModelSpec {
        name: "large-v3-turbo-q8_0",
        file_name: "ggml-large-v3-turbo-q8_0.bin",
        repo_path: "ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin",
        size_mb: 834,
        quality: "turbo 的 8bit 量化，几乎无损，体积更大",
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
        models_dir().join("ggml-large-v3-turbo-q5_0.bin")
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
        return models_dir().join("ggml-large-v3-turbo-q5_0.bin");
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
        // Per-read timeout instead of a global one: large models take minutes.
        .timeout_read(Duration::from_secs(60))
        .timeout_write(Duration::from_secs(60))
        .build();

    let mut last_error = String::from("没有可用的下载源");
    let mut finished = false;

    'hosts: for url in urls_for(spec) {
        // Three attempts per host; each resumes from the bytes already on disk.
        for attempt in 1..=3u32 {
            let existing = fs::metadata(&part).map(|meta| meta.len()).unwrap_or(0);
            log::info!(
                "下载模型 {}（约 {} MB）：{url}（第 {attempt} 次，已有 {:.1} MB）",
                spec.name,
                spec.size_mb,
                existing as f64 / (1024.0 * 1024.0)
            );

            let request = agent.get(&url);
            let request = if existing > 0 {
                request.set("Range", &format!("bytes={existing}-"))
            } else {
                request
            };

            let response = match request.call() {
                Ok(response) => response,
                Err(error) => {
                    log::warn!("下载源不可用：{url}（{error}）");
                    last_error = format!("{url}: {error}");
                    break;
                }
            };

            let resuming = existing > 0 && response.status() == 206;
            if existing > 0 && !resuming {
                // Server ignored the range request; restart this source from scratch.
                let _ = fs::remove_file(&part);
            }
            let already = if resuming { existing } else { 0 };
            let total = response
                .header("Content-Length")
                .and_then(|value| value.parse::<u64>().ok())
                .map(|remaining| remaining + already);

            let mut reader = response.into_reader();
            let mut file = if resuming {
                std::fs::OpenOptions::new().append(true).open(&part)
            } else {
                File::create(&part)
            }
            .map_err(|e| format!("无法写入 {}：{e}", part.display()))?;

            let mut buffer = [0u8; 128 * 1024];
            let mut received = already;
            let mut last_report = Instant::now();
            let mut failed = None;

            loop {
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(read) => {
                        if let Err(error) = file.write_all(&buffer[..read]) {
                            failed = Some(format!("写入失败：{error}"));
                            break;
                        }
                        received += read as u64;
                        if last_report.elapsed() >= Duration::from_millis(200) {
                            last_report = Instant::now();
                            progress(Progress { received, total });
                        }
                    }
                    Err(error) => {
                        failed = Some(format!("下载中断：{error}"));
                        break;
                    }
                }
            }
            let _ = file.sync_all();
            drop(file);

            if let Some(error) = failed {
                last_error = format!("{url}: {error}");
                log::warn!("{last_error}，准备续传");
                if attempt < 3 {
                    std::thread::sleep(Duration::from_secs(attempt as u64));
                }
                continue;
            }

            progress(Progress { received, total: total.or(Some(received)) });
            finished = true;
            break 'hosts;
        }
    }

    if !finished {
        return Err(format!(
            "下载失败（{}）：{}。\n已下载的部分会保留，重新执行即可续传；\n也可设置 VIBEBOARD_MODEL_MIRROR 指定镜像。",
            spec.name, last_error
        ));
    }

    fs::rename(&part, &target).map_err(|e| format!("无法保存模型：{e}"))?;
    log::info!("模型就绪：{}", target.display());
    Ok(target)
}

/// Best-effort download of the default model when nothing is installed yet.
pub fn ensure_default(progress: impl FnMut(Progress)) -> Result<PathBuf, String> {
    ensure("large-v3-turbo-q5_0", progress)
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
