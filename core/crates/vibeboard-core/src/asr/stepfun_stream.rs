//! StepFun bidirectional streaming ASR (`wss://api.stepfun.com/v1/realtime/asr/stream`).
//!
//! Protocol:
//! 1. connect with `Authorization: Bearer <key>`
//! 2. send `session.update` with the PCM format and transcription model
//! 3. wait for `session.updated`
//! 4. stream `input_audio_buffer.append` messages (base64 PCM16, <= 6400 bytes each)
//! 5. on release send `input_audio_buffer.commit`
//! 6. `...transcription.delta` revises the partial text, `...transcription.completed` is final

use std::io;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use base64::Engine;
use serde_json::{json, Value};
use std::net::TcpStream;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{connect, Message, WebSocket};

use super::{AsrProvider, AsrSink, SAMPLE_RATE};

const URL: &str = "wss://api.stepfun.com/v1/realtime/asr/stream";
const MAX_CHUNK: usize = 6400;
const MAX_PENDING_BYTES: usize = SAMPLE_RATE as usize * 2 * 15; // 15 s of audio
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const FINAL_TIMEOUT: Duration = Duration::from_secs(60);
const READ_POLL: Duration = Duration::from_millis(20);

enum Command {
    Audio(Vec<u8>),
    Finish,
    Stop,
}

pub struct StepFunStreamAsr {
    model: String,
    key: String,
    sink: Arc<dyn AsrSink>,
    tx: Option<Sender<Command>>,
    thread: Option<JoinHandle<()>>,
}

impl StepFunStreamAsr {
    pub fn new(model: impl Into<String>, key: impl Into<String>, sink: Arc<dyn AsrSink>) -> Self {
        Self {
            model: model.into(),
            key: key.into(),
            sink,
            tx: None,
            thread: None,
        }
    }
}

impl AsrProvider for StepFunStreamAsr {
    fn name(&self) -> &'static str {
        "stepfun-stream"
    }

    fn start(&mut self) -> Result<(), String> {
        if self.key.trim().is_empty() {
            return Err("请在语音识别设置中填写 StepFun API Key".into());
        }
        let (tx, rx) = mpsc::channel();
        self.tx = Some(tx);
        let model = self.model.clone();
        let key = self.key.clone();
        let sink = Arc::clone(&self.sink);
        self.thread = Some(
            thread::Builder::new()
                .name("stepfun-asr".into())
                .spawn(move || {
                    if let Err(message) = run(&model, &key, Arc::clone(&sink), rx) {
                        sink.on_error(&message);
                    }
                })
                .map_err(|e| format!("无法启动识别线程：{e}"))?,
        );
        Ok(())
    }

    fn send_pcm(&mut self, pcm16: &[u8]) {
        if let Some(tx) = &self.tx {
            let _ = tx.send(Command::Audio(pcm16.to_vec()));
        }
    }

    fn finish(&mut self) {
        if let Some(tx) = &self.tx {
            let _ = tx.send(Command::Finish);
        }
    }

    fn stop(&mut self) {
        if let Some(tx) = &self.tx {
            let _ = tx.send(Command::Stop);
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        self.tx = None;
    }
}

impl Drop for StepFunStreamAsr {
    fn drop(&mut self) {
        self.stop();
    }
}

fn run(
    model: &str,
    key: &str,
    sink: Arc<dyn AsrSink>,
    rx: Receiver<Command>,
) -> Result<(), String> {
    let request = tungstenite::http::Request::builder()
        .uri(URL)
        .header("Authorization", format!("Bearer {key}"))
        .body(())
        .map_err(|e| format!("构建请求失败：{e}"))?;

    let (mut socket, _response) = connect(request).map_err(|e| format!("StepFun 连接失败：{e}"))?;
    set_read_timeout(&socket, READ_POLL);

    let configuration = json!({
        "type": "session.update",
        "event_id": uuid::Uuid::new_v4().to_string(),
        "session": {
            "audio": {
                "input": {
                    "format": { "type": "pcm", "codec": "pcm_s16le", "rate": SAMPLE_RATE, "bits": 16, "channel": 1 },
                    "transcription": {
                        "model": model,
                        "language": "zh",
                        "full_rerun_on_commit": true,
                        "enable_itn": true
                    }
                }
            }
        }
    });
    send_json(&mut socket, &configuration)?;

    log::info!("StepFun 流式建连 model={model}");

    let started = Instant::now();
    let mut ready = false;
    let mut finishing = false;
    let mut committing = false;
    let mut sent_chunks = 0usize;
    let mut pending: Vec<u8> = Vec::new();
    let mut text = String::new();
    let mut commit_deadline: Option<Instant> = None;

    loop {
        // ---- outbound ----
        loop {
            match rx.try_recv() {
                Ok(Command::Audio(pcm)) => {
                    pending.extend_from_slice(&pcm);
                    if pending.len() > MAX_PENDING_BYTES {
                        return Err("网络发送过慢，请重新录制".into());
                    }
                }
                Ok(Command::Finish) => {
                    finishing = true;
                    commit_deadline = Some(Instant::now() + FINAL_TIMEOUT);
                }
                Ok(Command::Stop) | Err(mpsc::TryRecvError::Disconnected) => {
                    let _ = socket.close(None);
                    return Ok(());
                }
                Err(mpsc::TryRecvError::Empty) => break,
            }
        }

        if ready {
            while !pending.is_empty() {
                let take = pending.len().min(MAX_CHUNK);
                let chunk: Vec<u8> = pending.drain(..take).collect();
                let payload = base64::engine::general_purpose::STANDARD.encode(&chunk);
                send_json(
                    &mut socket,
                    &json!({
                        "type": "input_audio_buffer.append",
                        "event_id": uuid::Uuid::new_v4().to_string(),
                        "audio": payload
                    }),
                )?;
                sent_chunks += 1;
                if sent_chunks == 1 || sent_chunks % 50 == 0 {
                    log::debug!("StepFun 已发送音频块 {sent_chunks}");
                }
            }
            if finishing && !committing {
                committing = true;
                send_json(
                    &mut socket,
                    &json!({
                        "type": "input_audio_buffer.commit",
                        "event_id": uuid::Uuid::new_v4().to_string()
                    }),
                )?;
                log::info!("StepFun 音频已提交：{sent_chunks} 块");
            }
        }

        // ---- inbound ----
        match socket.read() {
            Ok(Message::Text(body)) => {
                if handle_event(
                    body.as_str(),
                    model,
                    &sink,
                    &mut text,
                    &mut ready,
                    &mut committing,
                )? {
                    let _ = socket.close(None);
                    return Ok(());
                }
            }
            Ok(Message::Binary(bytes)) => {
                if let Ok(body) = std::str::from_utf8(&bytes) {
                    if handle_event(body, model, &sink, &mut text, &mut ready, &mut committing)? {
                        let _ = socket.close(None);
                        return Ok(());
                    }
                }
            }
            Ok(Message::Close(_)) => return Err("StepFun 连接已关闭".into()),
            Ok(_) => {}
            Err(tungstenite::Error::Io(error))
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) => {}
            Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                return Ok(())
            }
            Err(error) => return Err(format!("StepFun 流式连接中断：{error}")),
        }

        if !ready && started.elapsed() > CONNECT_TIMEOUT {
            return Err("云端连接超时，请检查网络".into());
        }
        if let Some(deadline) = commit_deadline {
            if Instant::now() > deadline {
                return Err("云端识别超时，请重试".into());
            }
        }
    }
}

/// Returns `Ok(true)` when the transcription is complete and the worker should exit.
fn handle_event(
    body: &str,
    model: &str,
    sink: &Arc<dyn AsrSink>,
    text: &mut String,
    ready: &mut bool,
    committing: &mut bool,
) -> Result<bool, String> {
    let Ok(event) = serde_json::from_str::<Value>(body) else {
        return Ok(false);
    };
    match event.get("type").and_then(Value::as_str) {
        Some("session.updated") => {
            log::info!("StepFun 会话就绪");
            *ready = true;
        }
        Some("conversation.item.input_audio_transcription.delta") => {
            let delta = event
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if model == "step-asr-1.1-stream" {
                text.push_str(delta);
            } else {
                *text = delta.to_string();
            }
            sink.on_text(text, false);
        }
        Some("conversation.item.input_audio_transcription.completed") => {
            if !*committing {
                return Ok(false);
            }
            let final_text = event
                .get("transcript")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
                .unwrap_or_else(|| text.clone());
            log::info!("StepFun 转录完成：{} 字符", final_text.chars().count());
            sink.on_text(&final_text, true);
            return Ok(true);
        }
        Some("error") => {
            let code = event
                .get("error")
                .and_then(|e| e.get("code"))
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            log::warn!("StepFun 错误事件 code={code}");
            return Err("StepFun 流式识别失败，请检查模型与音频配置".into());
        }
        _ => {}
    }
    Ok(false)
}

fn send_json(
    socket: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    value: &Value,
) -> Result<(), String> {
    socket
        .send(Message::Text(value.to_string()))
        .map_err(|e| format!("发送失败：{e}"))
}

fn set_read_timeout(socket: &WebSocket<MaybeTlsStream<TcpStream>>, timeout: Duration) {
    // A read timeout is what paces the single-threaded socket loop: every timeout tick
    // drains the outbound audio queue.
    match socket.get_ref() {
        MaybeTlsStream::Plain(stream) => {
            let _ = stream.set_read_timeout(Some(timeout));
        }
        MaybeTlsStream::Rustls(stream) => {
            let _ = stream.get_ref().set_read_timeout(Some(timeout));
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[derive(Default)]
    struct RecordingSink {
        text: Mutex<Vec<(String, bool)>>,
        errors: Mutex<Vec<String>>,
    }

    impl AsrSink for RecordingSink {
        fn on_text(&self, text: &str, is_final: bool) {
            self.text.lock().unwrap().push((text.to_string(), is_final));
        }
        fn on_error(&self, message: &str) {
            self.errors.lock().unwrap().push(message.to_string());
        }
    }

    fn sink() -> (Arc<RecordingSink>, Arc<dyn AsrSink>) {
        let recording = Arc::new(RecordingSink::default());
        let dynamic: Arc<dyn AsrSink> = recording.clone();
        (recording, dynamic)
    }

    #[test]
    fn deltas_replace_text_for_revision_models() {
        let (recording, dynamic) = sink();
        let mut text = String::new();
        let mut ready = false;
        let mut committing = false;

        handle_event(
            r#"{"type":"conversation.item.input_audio_transcription.delta","text":"你好"}"#,
            "stepaudio-2.5-asr-stream",
            &dynamic,
            &mut text,
            &mut ready,
            &mut committing,
        )
        .unwrap();
        handle_event(
            r#"{"type":"conversation.item.input_audio_transcription.delta","text":"你好世界"}"#,
            "stepaudio-2.5-asr-stream",
            &dynamic,
            &mut text,
            &mut ready,
            &mut committing,
        )
        .unwrap();

        assert_eq!(text, "你好世界");
        let captured = recording.text.lock().unwrap();
        assert_eq!(captured.last().unwrap(), &("你好世界".to_string(), false));
    }

    #[test]
    fn deltas_append_for_incremental_model() {
        let (_, dynamic) = sink();
        let mut text = String::new();
        let mut ready = false;
        let mut committing = false;
        for delta in ["你好", "，世界"] {
            let event = format!(
                r#"{{"type":"conversation.item.input_audio_transcription.delta","text":"{delta}"}}"#
            );
            handle_event(
                &event,
                "step-asr-1.1-stream",
                &dynamic,
                &mut text,
                &mut ready,
                &mut committing,
            )
            .unwrap();
        }
        assert_eq!(text, "你好，世界");
    }

    #[test]
    fn completion_is_ignored_until_commit_and_finishes_afterwards() {
        let (recording, dynamic) = sink();
        let mut text = "草稿".to_string();
        let mut ready = false;
        let mut committing = false;

        let completed = r#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"最终文本"}"#;
        assert!(!handle_event(
            completed,
            "stepaudio-2.5-asr-stream",
            &dynamic,
            &mut text,
            &mut ready,
            &mut committing
        )
        .unwrap());
        assert!(recording.text.lock().unwrap().is_empty());

        committing = true;
        assert!(handle_event(
            completed,
            "stepaudio-2.5-asr-stream",
            &dynamic,
            &mut text,
            &mut ready,
            &mut committing
        )
        .unwrap());
        assert_eq!(
            recording.text.lock().unwrap().last().unwrap(),
            &("最终文本".to_string(), true)
        );
    }

    #[test]
    fn completed_without_transcript_falls_back_to_accumulated_text() {
        let (recording, dynamic) = sink();
        let mut text = "累积文本".to_string();
        let mut ready = false;
        let mut committing = true;
        assert!(handle_event(
            r#"{"type":"conversation.item.input_audio_transcription.completed"}"#,
            "stepaudio-2.5-asr-stream",
            &dynamic,
            &mut text,
            &mut ready,
            &mut committing
        )
        .unwrap());
        assert_eq!(recording.text.lock().unwrap().last().unwrap().0, "累积文本");
    }

    #[test]
    fn error_event_surfaces_message() {
        let (_, dynamic) = sink();
        let mut text = String::new();
        let mut ready = false;
        let mut committing = true;
        let result = handle_event(
            r#"{"type":"error","error":{"code":"invalid_audio"}}"#,
            "stepaudio-2.5-asr-stream",
            &dynamic,
            &mut text,
            &mut ready,
            &mut committing,
        );
        assert!(result.is_err());
    }

    #[test]
    fn missing_key_fails_fast() {
        let (_, dynamic) = sink();
        let mut provider = StepFunStreamAsr::new("stepaudio-2.5-asr-stream", "", dynamic);
        assert!(provider.start().is_err());
    }
}
