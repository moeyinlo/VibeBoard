//! Headless harness for the shared core.
//!
//! Two modes:
//! - default: full stack (discovery -> link -> auth -> session -> ASR), prints transcripts
//! - `--probe`: raw protocol/audio inspection without recognition
//!
//! Examples:
//! ```text
//! vibeboard --asr-key sk-... ...   # 按设备按键说话，打印识别结果
//! vibeboard --probe                # 只验证串口协议
//! vibeboard --provider external --record out.wav   # 录设备音频（不做识别）
//! vibeboard --replay frames.bin    # 离线解析抓包（CI）
//! ```

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use vibeboard_core::app::{App, AppConfig, Credentials, MemoryCredentials};
use vibeboard_core::auth::DeviceAuthClient;
use vibeboard_core::discovery::{self, DevicePresence};
use vibeboard_core::link::{LinkConfig, LinkSink, SerialLink};
use vibeboard_core::opus::OpusPcmDecoder;
use vibeboard_core::protocol::{AudioFrame, DeviceEvent, DeviceInfo, FrameParser, Incoming};
use vibeboard_core::session::{ProviderChoice, SessionConfig, SessionSink};
use vibeboard_core::{DEVICE_PID, DEVICE_VID};

fn main() {
    let args = Args::parse();
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or(if args.verbose { "debug" } else { "info" }),
    )
    .format_timestamp_millis()
    .init();

    if let Some(model) = &args.download_model {
        download_model(model);
        return;
    }

    if let Some(path) = &args.benchmark {
        benchmark(path);
        return;
    }

    if let Some(path) = &args.transcribe {
        transcribe_file(path, &args.whisper_model);
        return;
    }

    if let Some(path) = &args.replay {
        replay(path);
        return;
    }

    let code = if args.probe {
        run_probe(&args)
    } else {
        run_app(&args)
    };
    std::process::exit(code);
}

// ---------------------------------------------------------------------------
// Full stack
// ---------------------------------------------------------------------------

fn run_app(args: &Args) -> i32 {
    let key = args
        .asr_key
        .clone()
        .or_else(|| std::env::var("STEPFUN_API_KEY").ok())
        .unwrap_or_default();
    let provider = ProviderChoice::parse(&args.provider).unwrap_or(ProviderChoice::StepFun);

    if provider == ProviderChoice::Whisper
        && vibeboard_core::models::resolve(&args.whisper_model).is_none()
    {
        let path = vibeboard_core::models::path_for(&args.whisper_model);
        eprintln!("本地模型不存在：{}", path.display());
        eprintln!("先下载：vibeboard --download-model {}", args.whisper_model);
        return 1;
    }
    if provider == ProviderChoice::StepFun && key.trim().is_empty() {
        eprintln!("缺少 StepFun API Key：请传 --asr-key 或设置 STEPFUN_API_KEY。");
        eprintln!("（只想验证串口协议可加 --probe）");
        return 1;
    }
    if args.record.is_some() && provider != ProviderChoice::External {
        eprintln!("提示：--record 只在 --provider external 下录制设备 PCM；当前配置不会写文件。");
    }

    let sink = Arc::new(AppConsoleSink::default());
    let config = AppConfig {
        session: SessionConfig {
            provider,
            model: args.model.clone(),
            whisper_model: args.whisper_model.clone(),
            recognition_key: key,
            rewrite_enabled: args.rewrite,
            rewrite_model: args.rewrite_model.clone(),
            rewrite_key: args.rewrite_key.clone().unwrap_or_default(),
            button_actions: Default::default(),
        },
        base_url: args.base_url.clone(),
        registration_token: None,
        scan_interval: Duration::from_secs(2),
    };

    if provider == ProviderChoice::Whisper {
        #[cfg(feature = "whisper")]
        {
            let info = vibeboard_core::asr::whisper::backend_info();
            println!(
                "本地引擎：{}（已编译后端：{:?}）",
                info.active, info.compiled
            );
            if let Some(first) = info
                .system_info
                .lines()
                .find(|line| !line.trim().is_empty())
            {
                println!("运行环境：{}", first.trim());
            }
        }
    }
    println!(
        "启动：provider={} model={}",
        args.provider,
        if provider == ProviderChoice::Whisper {
            args.whisper_model.as_str()
        } else {
            args.model.as_str()
        }
    );

    let credentials: Arc<dyn Credentials> = Arc::new(MemoryCredentials::default());
    let mut app = App::start(config, sink.clone(), credentials);

    let started = Instant::now();
    loop {
        if args.seconds > 0 && started.elapsed() >= Duration::from_secs(args.seconds) {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }

    app.stop();
    if args.provider == "external" {
        if let Some(path) = &args.record {
            match sink.write_wav(path) {
                Ok(bytes) => println!("已写入 {}（{} 字节 PCM）", path.display(), bytes),
                Err(error) => eprintln!("写入 WAV 失败：{error}"),
            }
        }
    }
    println!(
        "退出。共 {} 次识别，输出 {} 帧 PCM",
        sink.sessions(),
        sink.pcm_bytes()
    );
    0
}

#[derive(Default)]
struct AppConsoleSink {
    pcm: Mutex<Vec<u8>>,
    sessions: AtomicU64,
    finals: AtomicU64,
}

impl AppConsoleSink {
    fn sessions(&self) -> u64 {
        self.sessions.load(Ordering::Relaxed)
    }

    fn pcm_bytes(&self) -> usize {
        self.pcm.lock().map(|pcm| pcm.len()).unwrap_or(0)
    }

    fn write_wav(&self, path: &PathBuf) -> std::io::Result<usize> {
        let pcm = self.pcm.lock().unwrap();
        let wav = vibeboard_core::asr::wav_from_pcm16(&pcm, 16_000);
        std::fs::write(path, wav)?;
        Ok(pcm.len())
    }
}

impl SessionSink for AppConsoleSink {
    fn status(&self, text: &str) {
        println!("[status] {text}");
    }

    fn partial_text(&self, text: &str) {
        println!("[partial] {text}");
    }

    fn final_text(&self, text: &str) {
        self.finals.fetch_add(1, Ordering::Relaxed);
        println!("[final] {text}");
    }

    fn session_started(&self) {
        self.sessions.fetch_add(1, Ordering::Relaxed);
        println!("[session] 开始录音（请对着设备说话，说完松开）");
    }

    fn cancelled(&self) {
        println!("[session] 已取消");
    }

    fn error(&self, message: &str) {
        eprintln!("[error] {message}");
    }

    fn action(&self, action: &str) {
        println!("[action] 按键动作：{action}");
    }

    fn external_pcm(&self, pcm: &[u8]) {
        self.pcm.lock().unwrap().extend_from_slice(pcm);
    }

    fn external_pcm_end(&self) {
        println!("[external] 本段音频结束（{} 字节）", self.pcm_bytes());
    }

    fn local_stats(&self, stats: &vibeboard_core::asr::LocalStats) {
        println!("[local] {}", stats.summary());
        for line in stats.system_info.lines().take(6) {
            if !line.trim().is_empty() {
                println!("[local:env] {}", line.trim());
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Probe mode: protocol + audio without recognition
// ---------------------------------------------------------------------------

fn run_probe(args: &Args) -> i32 {
    let presence = match args.port.clone() {
        Some(port) => DevicePresence {
            port_name: port.clone(),
            serial: args.serial.clone().unwrap_or_default(),
            product: None,
            vendor_id: DEVICE_VID,
            product_id: DEVICE_PID,
        },
        None => match wait_for_device(Duration::from_secs(args.wait)) {
            Some(presence) => presence,
            None => {
                eprintln!(
                    "未发现 VibeBoard 设备（VID 303A / PID 1001）。请确认 USB 已连接后重试。"
                );
                return 2;
            }
        },
    };

    println!(
        "设备: port={} serial={:?}",
        presence.port_name, presence.serial
    );

    let sink = Arc::new(ProbeSink::default());
    let config = LinkConfig::new(presence.port_name.clone());
    let link = match SerialLink::open(config, sink.clone()) {
        Ok(link) => link,
        Err(error) => {
            eprintln!("打开串口失败: {error}");
            return 3;
        }
    };

    let started = Instant::now();
    let mut auth_done = false;
    let mut last_report = Instant::now();

    loop {
        if args.seconds > 0 && started.elapsed() >= Duration::from_secs(args.seconds) {
            break;
        }

        if args.auth && !auth_done {
            let info = sink.info.lock().unwrap().clone();
            if let Some(info) = info {
                auth_done = true;
                let mac = presence.serial.clone();
                let hardware = if info.hardware.is_empty() {
                    "vibe_keyboard".to_string()
                } else {
                    info.hardware.clone()
                };
                let client = DeviceAuthClient::new(args.base_url.clone());
                let result: Result<(), String> = (|| {
                    if mac.is_empty() {
                        return Err("设备序列号为空，无法注册".to_string());
                    }
                    let registered = client
                        .register(&mac, &hardware, None)
                        .map_err(|e| e.to_string())?;
                    println!(
                        "注册成功: device_id={} secret={} provisioned={}",
                        registered.device_id,
                        if registered.secret.is_some() {
                            "yes"
                        } else {
                            "no"
                        },
                        registered.provisioned
                    );
                    let secret = registered
                        .secret
                        .ok_or_else(|| "注册响应未返回 device_secret".to_string())?;
                    link.send_provision(&registered.device_id, &secret);
                    let token = client
                        .valid_token(&registered.device_id, &secret)
                        .map_err(|e| e.to_string())?;
                    println!("token OK: {}…", &token[..token.len().min(12)]);
                    Ok(())
                })();
                if let Err(message) = result {
                    eprintln!("鉴权失败: {message}");
                }
            }
        }

        if last_report.elapsed() >= Duration::from_secs(1) {
            last_report = Instant::now();
            println!("{}", sink.stats_line(started.elapsed()));
        }

        std::thread::sleep(Duration::from_millis(100));
    }

    link.close();
    if let Some(path) = &args.record {
        match sink.write_wav(path) {
            Ok(bytes) => println!("已写入 {} ({} 字节 PCM)", path.display(), bytes),
            Err(error) => eprintln!("写入 WAV 失败: {error}"),
        }
    }
    println!("退出。\n{}", sink.stats_line(started.elapsed()));
    0
}

fn wait_for_device(timeout: Duration) -> Option<DevicePresence> {
    let deadline = Instant::now() + timeout;
    let mut last_log = Instant::now() - Duration::from_secs(5);
    while Instant::now() < deadline {
        match discovery::find_device() {
            Ok(Some(presence)) => return Some(presence),
            Ok(None) => {}
            Err(error) => eprintln!("枚举串口失败: {error}"),
        }
        if last_log.elapsed() >= Duration::from_secs(5) {
            last_log = Instant::now();
            println!("等待设备接入…");
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    None
}

#[derive(Default)]
struct ProbeSink {
    decoder: Mutex<Option<OpusPcmDecoder>>,
    pcm: Mutex<Vec<u8>>,
    info: Mutex<Option<DeviceInfo>>,
    audio_frames: AtomicU64,
    audio_bytes: AtomicU64,
    decode_failures: AtomicU64,
    events: AtomicU64,
}

impl ProbeSink {
    fn decoder(&self) -> std::sync::MutexGuard<'_, Option<OpusPcmDecoder>> {
        let mut guard = self.decoder.lock().unwrap();
        if guard.is_none() {
            match OpusPcmDecoder::new() {
                Ok(decoder) => *guard = Some(decoder),
                Err(error) => log::error!("创建 Opus 解码器失败: {error}"),
            }
        }
        guard
    }

    fn stats_line(&self, elapsed: Duration) -> String {
        let frames = self.audio_frames.load(Ordering::Relaxed);
        let bytes = self.audio_bytes.load(Ordering::Relaxed);
        let seconds = elapsed.as_secs_f64().max(0.001);
        format!(
            "[stats] {:.0}s 音频帧={} PCM={} 采样={} 解码失败={} 事件={} 吞吐={:.1} KB/s",
            elapsed.as_secs_f64(),
            frames,
            bytes,
            bytes / 2,
            self.decode_failures.load(Ordering::Relaxed),
            self.events.load(Ordering::Relaxed),
            bytes as f64 / 1024.0 / seconds
        )
    }

    fn write_wav(&self, path: &PathBuf) -> std::io::Result<usize> {
        let pcm = self.pcm.lock().unwrap();
        std::fs::write(path, vibeboard_core::asr::wav_from_pcm16(&pcm, 16_000))?;
        Ok(pcm.len())
    }
}

impl LinkSink for ProbeSink {
    fn on_audio(&self, frame: AudioFrame) {
        let count = self.audio_frames.fetch_add(1, Ordering::Relaxed) + 1;
        let mut decoder = self.decoder();
        if let Some(decoder) = decoder.as_mut() {
            match decoder.decode_to_pcm16(&frame.payload) {
                Ok(pcm) => {
                    if !pcm.is_empty() {
                        self.audio_bytes
                            .fetch_add(pcm.len() as u64, Ordering::Relaxed);
                        self.pcm.lock().unwrap().extend_from_slice(&pcm);
                    }
                }
                Err(error) => {
                    self.decode_failures.fetch_add(1, Ordering::Relaxed);
                    log::warn!("Opus 解码失败 seq={}: {error}", frame.sequence);
                }
            }
        }
        if count == 1 || count % 50 == 0 || frame.is_last() {
            println!(
                "[audio] #{} session={} seq={} bytes={} flags=0x{:x} last={}",
                count,
                frame.session_id,
                frame.sequence,
                frame.payload.len(),
                frame.flags,
                frame.is_last()
            );
        }
    }

    fn on_event(&self, event: DeviceEvent, raw: &serde_json::Value) {
        self.events.fetch_add(1, Ordering::Relaxed);
        match &event {
            DeviceEvent::DeviceInfo(info) => {
                println!(
                    "[device_info] id={} hw={} fw={} provisioned={} buttons={:?}",
                    info.device_id,
                    info.hardware,
                    info.firmware_version,
                    info.provisioned,
                    info.buttons
                );
                *self.info.lock().unwrap() = Some(info.clone());
            }
            DeviceEvent::ButtonDown { button, session_id } => {
                println!("[button] down {button} session={session_id}");
            }
            DeviceEvent::ButtonUp {
                button,
                session_id,
                duration_ms,
            } => {
                println!("[button] up {button} session={session_id} duration={duration_ms}ms");
            }
            DeviceEvent::ButtonClick {
                button,
                duration_ms,
            } => {
                println!("[button] click {button} duration={duration_ms}ms");
            }
            DeviceEvent::ProvisionAck { ok, message } => {
                println!("[device] provision_ack ok={ok} message={message:?}");
            }
            DeviceEvent::Other(_) => println!("[device] {raw}"),
        }
    }

    fn on_raw(&self, bytes: &[u8]) {
        match std::str::from_utf8(bytes) {
            Ok(text) if !text.trim().is_empty() => println!("[raw] {}", text.trim()),
            _ => println!(
                "[raw] {} bytes {:02x?}",
                bytes.len(),
                &bytes[..bytes.len().min(24)]
            ),
        }
    }

    fn on_ready(&self, info: &DeviceInfo) {
        println!(
            "[ready] 设备握手完成 id={} fw={} hw={}",
            info.device_id, info.firmware_version, info.hardware
        );
    }

    fn on_disconnected(&self, reason: &str) {
        println!("[disconnect] {reason}");
    }

    fn on_error(&self, message: &str) {
        eprintln!("[error] {message}");
    }
}

/// Minimal WAV reader: mono 16-bit PCM at any rate (resampled to 16 kHz), stereo downmixed.
fn read_wav_pcm16_16k(path: &PathBuf) -> Result<Vec<u8>, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("读取 {} 失败：{e}", path.display()))?;
    if bytes.len() < 44 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("不是有效的 WAV 文件".into());
    }
    let mut offset = 12;
    let mut channels = 1u16;
    let mut bits = 16u16;
    let mut rate = 16_000u32;
    let mut data: Option<&[u8]> = None;
    while offset + 8 <= bytes.len() {
        let id = &bytes[offset..offset + 4];
        let size = u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().unwrap()) as usize;
        let body = &bytes[offset + 8..(offset + 8 + size).min(bytes.len())];
        match id {
            b"fmt " => {
                channels = u16::from_le_bytes(body[2..4].try_into().unwrap()).max(1);
                rate = u32::from_le_bytes(body[4..8].try_into().unwrap()).max(1);
                bits = u16::from_le_bytes(body[14..16].try_into().unwrap());
            }
            b"data" => data = Some(body),
            _ => {}
        }
        offset += 8 + size + (size & 1);
    }
    let data = data.ok_or("WAV 缺少 data 段")?;
    if bits != 16 {
        return Err(format!("只支持 16 位 PCM，当前 {bits} 位"));
    }
    let mut pcm: Vec<u8> = Vec::with_capacity(data.len());
    let frames = data.len() / (2 * channels as usize);
    for frame in 0..frames {
        let base = frame * 2 * channels as usize;
        pcm.extend_from_slice(&data[base..base + 2]);
    }
    if rate == 16_000 || pcm.is_empty() {
        return Ok(pcm);
    }
    // Linear resample to 16 kHz (adequate for benchmarking).
    let samples: Vec<i16> = pcm
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    let ratio = rate as f64 / 16_000.0;
    let out_len = ((samples.len() as f64) / ratio) as usize;
    let mut out = Vec::with_capacity(out_len * 2);
    for index in 0..out_len {
        let src = index as f64 * ratio;
        let low = src.floor() as usize;
        let high = (low + 1).min(samples.len() - 1);
        let frac = src - low as f64;
        let value = samples[low] as f64 * (1.0 - frac) + samples[high] as f64 * frac;
        out.extend_from_slice(&(value as i16).to_le_bytes());
    }
    Ok(out)
}

fn transcribe_file(path: &PathBuf, model: &str) {
    let pcm = match read_wav_pcm16_16k(path) {
        Ok(pcm) => pcm,
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    };
    let model_path = vibeboard_core::models::path_for(model);
    println!("模型：{}", model_path.display());
    match vibeboard_core::asr::whisper::transcribe_pcm(&model_path, "zh", &pcm) {
        Ok((text, stats)) => {
            println!("识别：{text}");
            println!("统计：{}", stats.summary());
        }
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

/// Runs every installed model against the same audio for an apples-to-apples comparison.
fn benchmark(path: &PathBuf) {
    let pcm = match read_wav_pcm16_16k(path) {
        Ok(pcm) => pcm,
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    };
    let audio_seconds = pcm.len() as f64 / 2.0 / 16_000.0;
    println!("音频：{}（{:.2}s）", path.display(), audio_seconds);
    println!();
    println!("| 模型 | 耗时 | RTF | 峰值内存 | 识别结果 |");
    println!("|---|---|---|---|---|");
    let mut ran = 0;
    for spec in vibeboard_core::models::MODELS {
        let model_path = vibeboard_core::models::path_for(spec.name);
        if !model_path.is_file() {
            continue;
        }
        ran += 1;
        match vibeboard_core::asr::whisper::transcribe_pcm(&model_path, "zh", &pcm) {
            Ok((text, stats)) => {
                println!(
                    "| {} ({:.0}MB) | {:.2}s | {:.2} | {} | {} |",
                    spec.name,
                    spec.size_mb,
                    stats.duration_seconds,
                    stats.realtime_factor,
                    stats
                        .peak_rss_mb
                        .map(|mb| format!("{mb:.0}MB"))
                        .unwrap_or_else(|| "-".into()),
                    text.replace('|', "\\|")
                );
            }
            Err(error) => println!("| {} | - | - | - | 失败：{error} |", spec.name),
        }
    }
    if ran == 0 {
        println!("没有已下载的模型。先运行：vibeboard --download-model small");
    }
}

fn download_model(model: &str) {
    if model.is_empty() {
        eprintln!("用法：vibeboard --download-model <tiny|base|small|medium|large-v3-turbo>");
        std::process::exit(1);
    }
    let mut last_percent = 0u32;
    let result = vibeboard_core::models::ensure(model, |progress| {
        let percent = progress.fraction().map(|f| (f * 100.0) as u32);
        if let Some(percent) = percent {
            if percent >= last_percent + 5 {
                last_percent = percent;
                println!("下载 {model}：{percent}%（{:.0} MB）", progress.megabytes());
            }
        }
    });
    match result {
        Ok(path) => println!("模型已就绪：{}", path.display()),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

/// Offline parser run: feeds a captured byte stream through the framing layer.
fn replay(path: &PathBuf) {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) => {
            eprintln!("读取 {} 失败: {error}", path.display());
            std::process::exit(2);
        }
    };
    let mut parser = FrameParser::new();
    let items = parser.feed(&bytes);
    let mut audio = 0;
    let mut events = 0;
    let mut raw_chunks = 0;
    let mut samples = 0usize;
    let mut decoder: Option<OpusPcmDecoder> = None;

    for item in items {
        match item {
            Incoming::Audio(frame) => {
                audio += 1;
                if decoder.is_none() {
                    decoder = OpusPcmDecoder::new().ok();
                }
                if let Some(decoder) = decoder.as_mut() {
                    if let Ok(chunk) = decoder.decode(&frame.payload) {
                        samples += chunk.len();
                    }
                }
            }
            Incoming::State(value) => {
                events += 1;
                match DeviceEvent::parse(&value) {
                    Some(event) => println!("{event:?}"),
                    None => println!("{value}"),
                }
            }
            Incoming::Raw(bytes) => {
                raw_chunks += 1;
                println!(
                    "[raw {}B] {}",
                    bytes.len(),
                    String::from_utf8_lossy(&bytes).trim()
                );
            }
        }
    }
    println!(
        "回放完成: 音频帧={audio} 事件={events} 原始块={raw_chunks} 解码采样={samples} 剩余缓冲={}B",
        parser.buffered()
    );
}

struct Args {
    port: Option<String>,
    serial: Option<String>,
    seconds: u64,
    auth: bool,
    base_url: String,
    record: Option<PathBuf>,
    replay: Option<PathBuf>,
    wait: u64,
    verbose: bool,
    probe: bool,
    provider: String,
    model: String,
    whisper_model: String,
    download_model: Option<String>,
    transcribe: Option<PathBuf>,
    benchmark: Option<PathBuf>,
    asr_key: Option<String>,
    rewrite: bool,
    rewrite_model: String,
    rewrite_key: Option<String>,
}

impl Args {
    fn parse() -> Self {
        let mut args = Args {
            port: None,
            serial: None,
            seconds: 0,
            auth: true,
            base_url: "https://torchfun.com".to_string(),
            record: None,
            replay: None,
            wait: 20,
            verbose: false,
            probe: false,
            provider: "stepfun".to_string(),
            model: "stepaudio-2.5-asr-stream".to_string(),
            whisper_model: "small".to_string(),
            download_model: None,
            transcribe: None,
            benchmark: None,
            asr_key: None,
            rewrite: false,
            rewrite_model: "step-3.5-flash".to_string(),
            rewrite_key: None,
        };
        let mut iter = std::env::args().skip(1);
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "--port" => args.port = iter.next(),
                "--serial" => args.serial = iter.next(),
                "--seconds" => args.seconds = iter.next().and_then(|v| v.parse().ok()).unwrap_or(0),
                "--base-url" => args.base_url = iter.next().unwrap_or(args.base_url),
                "--record" => args.record = iter.next().map(PathBuf::from),
                "--replay" => args.replay = iter.next().map(PathBuf::from),
                "--wait" => args.wait = iter.next().and_then(|v| v.parse().ok()).unwrap_or(20),
                "--provider" => args.provider = iter.next().unwrap_or(args.provider),
                "--model" => args.model = iter.next().unwrap_or(args.model),
                "--whisper-model" => args.whisper_model = iter.next().unwrap_or(args.whisper_model),
                "--download-model" => args.download_model = Some(iter.next().unwrap_or_default()),
                "--transcribe" => args.transcribe = iter.next().map(PathBuf::from),
                "--benchmark" => args.benchmark = iter.next().map(PathBuf::from),
                "--asr-key" => args.asr_key = iter.next(),
                "--rewrite" => args.rewrite = true,
                "--rewrite-model" => args.rewrite_model = iter.next().unwrap_or(args.rewrite_model),
                "--rewrite-key" => args.rewrite_key = iter.next(),
                "--no-auth" => args.auth = false,
                "--probe" => args.probe = true,
                "--verbose" | "-v" => args.verbose = true,
                "--help" | "-h" => {
                    print_help();
                    std::process::exit(0);
                }
                other => {
                    eprintln!("未知参数: {other}");
                    print_help();
                    std::process::exit(1);
                }
            }
        }
        args
    }
}

fn print_help() {
    println!(
        "vibeboard — VibeBoard 共享内核 CLI\n\
         \n\
         用法: vibeboard [选项]\n\
         \n\
         完整链路（默认）:\n\
           --asr-key <key>       StepFun API Key（也可用环境变量 STEPFUN_API_KEY）\n\
           --provider <name>     stepfun | whisper | external（默认 stepfun）\n\
           --whisper-model <m>   tiny | base | small | medium | large-v3-turbo 或路径（默认 small）\n\
           --download-model <m>  下载本地模型后退出\n\
           --model <id>          识别模型（默认 stepaudio-2.5-asr-stream）\n\
           --rewrite             开启语义整理（需要 --rewrite-key）\n\
           --rewrite-model <id>  整理模型（默认 step-3.5-flash）\n\
           --rewrite-key <key>   整理用 StepFun Key\n\
           --record <file>       仅 external 模式：把设备音频写成 WAV\n\
           --seconds <n>         运行时长，0 = 无限（默认）\n\
           --base-url <url>      鉴权服务器（默认 https://torchfun.com）\n\
         \n\
         协议自检:\n\
           --probe               只跑串口协议/音频统计，不做识别\n\
           --no-auth             配合 --probe 跳过注册\n\
           --port <path>         指定串口\n\
           --serial <mac>        指定注册序列号\n\
           --wait <n>            等待设备接入秒数（默认 20）\n\
           --transcribe <wav>    用指定模型识别本地 WAV（默认 small）\n\
           --benchmark <wav>     同一段 WAV 跑所有已下载模型并对比\n\
           --replay <file>       离线回放抓包字节流\n\
           --verbose             打印 debug 日志\n"
    );
}
