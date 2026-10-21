//! Headless harness for the shared core.
//!
//! Examples:
//! ```text
//! vibeboard                       # discover, handshake, register, decode audio for 30 s
//! vibeboard --seconds 0          # run until Ctrl-C
//! vibeboard --no-auth            # protocol only
//! vibeboard --record out.wav     # also store decoded 16 kHz PCM
//! vibeboard --replay frames.bin  # offline parse of a captured byte stream (CI)
//! ```

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use vibeboard_core::auth::DeviceAuthClient;
use vibeboard_core::discovery::{self, DevicePresence};
use vibeboard_core::link::{LinkConfig, LinkSink, SerialLink};
use vibeboard_core::opus::OpusPcmDecoder;
use vibeboard_core::protocol::{AudioFrame, DeviceEvent, DeviceInfo, FrameParser, Incoming};

fn main() {
    let args = Args::parse();
    env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or(if args.verbose { "debug" } else { "info" }),
    )
    .format_timestamp_millis()
    .init();

    if let Some(path) = &args.replay {
        replay(path);
        return;
    }

    let presence = match args.port.clone() {
        Some(port) => DevicePresence {
            port_name: port.clone(),
            serial: args.serial.clone().unwrap_or_default(),
            product: None,
            vendor_id: vibeboard_core::DEVICE_VID,
            product_id: vibeboard_core::DEVICE_PID,
        },
        None => match wait_for_device(Duration::from_secs(args.wait)) {
            Some(presence) => presence,
            None => {
                eprintln!(
                    "未发现 VibeBoard 设备（VID 303A / PID 1001）。请确认 USB 已连接后重试。"
                );
                std::process::exit(2);
            }
        },
    };

    println!(
        "设备: port={} serial={:?}",
        presence.port_name, presence.serial
    );

    let sink = Arc::new(ConsoleSink::default());
    let config = LinkConfig::new(presence.port_name.clone());
    let mut link = match SerialLink::open(config, sink.clone()) {
        Ok(link) => link,
        Err(error) => {
            eprintln!("打开串口失败: {error}");
            std::process::exit(3);
        }
    };

    let started = Instant::now();
    let mut auth_state = AuthState::Pending;
    let mut last_report = Instant::now();

    loop {
        let elapsed = started.elapsed();
        if args.seconds > 0 && elapsed >= Duration::from_secs(args.seconds) {
            break;
        }

        if args.auth && matches!(auth_state, AuthState::Pending) {
            let info = sink.info.lock().unwrap().clone();
            if let Some(info) = info {
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
                auth_state = match result {
                    Ok(()) => AuthState::Done,
                    Err(message) => {
                        eprintln!("鉴权失败: {message}");
                        AuthState::Failed
                    }
                };
                sink.record_token_checked(auth_state == AuthState::Done);
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
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AuthState {
    Pending,
    Done,
    Failed,
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
struct ConsoleSink {
    decoder: Mutex<Option<OpusPcmDecoder>>,
    pcm: Mutex<Vec<u8>>,
    info: Mutex<Option<DeviceInfo>>,
    audio_frames: AtomicU64,
    audio_bytes: AtomicU64,
    decode_failures: AtomicU64,
    events: AtomicU64,
    token_ok: AtomicBool,
    last_audio: Mutex<Option<Instant>>,
}

impl ConsoleSink {
    fn decoder(&self) -> std::sync::MutexGuard<'_, Option<OpusPcmDecoder>> {
        let mut guard = self.decoder.lock().unwrap();
        if guard.is_none() {
            match OpusPcmDecoder::new() {
                Ok(decoder) => *guard = Some(decoder),
                Err(error) => {
                    log::error!("创建 Opus 解码器失败: {error}");
                }
            }
        }
        guard
    }

    fn record_token_checked(&self, ok: bool) {
        self.token_ok.store(ok, Ordering::Relaxed);
    }

    fn stats_line(&self, elapsed: Duration) -> String {
        let frames = self.audio_frames.load(Ordering::Relaxed);
        let bytes = self.audio_bytes.load(Ordering::Relaxed);
        let samples = bytes / 2;
        let seconds = elapsed.as_secs_f64().max(0.001);
        format!(
            "[stats] {:.0}s 音频帧={} PCM={} 采样(合计)={} 解码失败={} 事件={} 吞吐={:.1} KB/s",
            elapsed.as_secs_f64(),
            frames,
            bytes,
            samples,
            self.decode_failures.load(Ordering::Relaxed),
            self.events.load(Ordering::Relaxed),
            bytes as f64 / 1024.0 / seconds
        )
    }

    fn write_wav(&self, path: &PathBuf) -> std::io::Result<usize> {
        let pcm = self.pcm.lock().unwrap();
        let mut file = std::fs::File::create(path)?;
        let data_len = pcm.len() as u32;
        let mut header = Vec::with_capacity(44);
        header.extend_from_slice(b"RIFF");
        header.extend_from_slice(&(36 + data_len).to_le_bytes());
        header.extend_from_slice(b"WAVEfmt ");
        header.extend_from_slice(&16u32.to_le_bytes());
        header.extend_from_slice(&1u16.to_le_bytes());
        header.extend_from_slice(&1u16.to_le_bytes());
        header.extend_from_slice(&16_000u32.to_le_bytes());
        header.extend_from_slice(&32_000u32.to_le_bytes());
        header.extend_from_slice(&2u16.to_le_bytes());
        header.extend_from_slice(&16u16.to_le_bytes());
        header.extend_from_slice(b"data");
        header.extend_from_slice(&data_len.to_le_bytes());
        use std::io::Write;
        file.write_all(&header)?;
        file.write_all(&pcm)?;
        Ok(pcm.len())
    }
}

impl LinkSink for ConsoleSink {
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
        *self.last_audio.lock().unwrap() = Some(Instant::now());
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
            DeviceEvent::Other(_) => {
                println!("[device] {raw}");
            }
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
                    if let Ok(samples_now) = decoder.decode(&frame.payload) {
                        samples += samples_now.len();
                    }
                }
            }
            Incoming::State(value) => {
                events += 1;
                if let Some(event) = DeviceEvent::parse(&value) {
                    println!("{event:?}");
                } else {
                    println!("{value}");
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
}

impl Args {
    fn parse() -> Self {
        let mut args = Args {
            port: None,
            serial: None,
            seconds: 30,
            auth: true,
            base_url: "https://torchfun.com".to_string(),
            record: None,
            replay: None,
            wait: 20,
            verbose: false,
        };
        let mut iter = std::env::args().skip(1);
        while let Some(arg) = iter.next() {
            match arg.as_str() {
                "--port" => args.port = iter.next(),
                "--serial" => args.serial = iter.next(),
                "--seconds" => {
                    args.seconds = iter.next().and_then(|v| v.parse().ok()).unwrap_or(30)
                }
                "--base-url" => args.base_url = iter.next().unwrap_or(args.base_url),
                "--record" => args.record = iter.next().map(PathBuf::from),
                "--replay" => args.replay = iter.next().map(PathBuf::from),
                "--wait" => args.wait = iter.next().and_then(|v| v.parse().ok()).unwrap_or(20),
                "--no-auth" => args.auth = false,
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
           --port <path>      指定串口（默认自动发现 303A:1001）\n\
           --serial <mac>     指定注册用序列号（配合 --port）\n\
           --seconds <n>      运行时长，0 = 无限（默认 30）\n\
           --wait <n>         等待设备接入秒数（默认 20）\n\
           --no-auth          跳过注册与 token 交换\n\
           --base-url <url>   鉴权服务器，默认 https://torchfun.com\n\
           --record <file>    把解码后的 PCM 写成 16 kHz 单声道 WAV\n\
           --replay <file>    回放抓包字节流（离线/CI 用），不连接硬件\n\
           --verbose          打印 debug 日志\n"
    );
}

#[allow(dead_code)]
fn probe_tcp(url: &str) -> bool {
    std::net::TcpStream::connect(url).is_ok()
}
