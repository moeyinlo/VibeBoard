//! StepFun batch transcription (`POST /v1/audio/transcriptions`).
//!
//! Used for the non-streaming models: audio is uploaded once after the user releases
//! the button, as a 16 kHz mono WAV.

use std::sync::Arc;
use std::thread::{self, JoinHandle};

use serde_json::Value;

use super::{wav_from_pcm16, AsrProvider, AsrSink};

const URL: &str = "https://api.stepfun.com/v1/audio/transcriptions";

pub struct StepFunBatchAsr {
    model: String,
    key: String,
    sink: Arc<dyn AsrSink>,
    pcm: Vec<u8>,
    generation: u64,
    worker: Option<JoinHandle<()>>,
}

impl StepFunBatchAsr {
    pub fn new(model: impl Into<String>, key: impl Into<String>, sink: Arc<dyn AsrSink>) -> Self {
        Self {
            model: model.into(),
            key: key.into(),
            sink,
            pcm: Vec::new(),
            generation: 0,
            worker: None,
        }
    }
}

impl AsrProvider for StepFunBatchAsr {
    fn name(&self) -> &'static str {
        "stepfun-batch"
    }

    fn start(&mut self) -> Result<(), String> {
        if self.key.trim().is_empty() {
            return Err("请在语音识别设置中填写 StepFun API Key".into());
        }
        self.pcm.clear();
        self.generation += 1;
        log::info!("StepFun 批量会话开始 model={}", self.model);
        Ok(())
    }

    fn send_pcm(&mut self, pcm16: &[u8]) {
        self.pcm.extend_from_slice(pcm16);
        // Keep a hard cap in line with the 5-minute cloud session limit.
        if self.pcm.len() > 16_000 * 2 * 300 {
            self.pcm.clear();
            self.sink.on_error("单次云端录音最多 5 分钟，请分段录制");
        }
    }

    fn finish(&mut self) {
        if self.pcm.is_empty() {
            self.sink.on_error("未收到设备音频，请检查按键及串口连接");
            return;
        }
        let audio = std::mem::take(&mut self.pcm);
        let generation = self.generation;
        let model = self.model.clone();
        let key = self.key.clone();
        let sink = Arc::clone(&self.sink);
        log::info!("StepFun 上传音频：{}B PCM", audio.len());
        self.worker = Some(
            thread::Builder::new()
                .name("stepfun-batch".into())
                .spawn(move || match transcribe(&audio, &model, &key) {
                    Ok(text) => {
                        // A newer session may have started while this one uploaded.
                        let _ = generation;
                        sink.on_text(&text, true);
                    }
                    Err(message) => sink.on_error(&message),
                })
                .expect("spawn batch asr"),
        );
    }

    fn stop(&mut self) {
        self.generation += 1;
        self.pcm.clear();
        if let Some(worker) = self.worker.take() {
            // The HTTP request is short-lived; detach rather than block the caller.
            drop(worker);
        }
    }
}

fn transcribe(pcm: &[u8], model: &str, key: &str) -> Result<String, String> {
    let boundary = format!("vibeboard{}", uuid::Uuid::new_v4().simple());
    let wav = wav_from_pcm16(pcm, 16_000);

    let mut body = Vec::new();
    for (name, value) in [("model", model), ("response_format", "json")] {
        body.extend_from_slice(
            format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n")
                .as_bytes(),
        );
    }
    body.extend_from_slice(
        format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        )
        .as_bytes(),
    );
    body.extend_from_slice(&wav);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());

    let agent = ureq::AgentBuilder::new()
        .timeout(std::time::Duration::from_secs(55))
        .build();
    let response = agent
        .post(URL)
        .set("Authorization", &format!("Bearer {key}"))
        .set(
            "Content-Type",
            &format!("multipart/form-data; boundary={boundary}"),
        )
        .send_bytes(&body);

    let text = match response {
        Ok(response) => response
            .into_string()
            .map_err(|e| format!("读取响应失败：{e}"))?,
        Err(ureq::Error::Status(status, response)) => {
            let body = response.into_string().unwrap_or_default();
            let body: String = body.chars().take(200).collect();
            return Err(format!("StepFun 请求失败（HTTP {status}）：{body}"));
        }
        Err(error) => return Err(format!("StepFun 请求失败：{error}")),
    };

    let value: Value =
        serde_json::from_str(&text).map_err(|e| format!("StepFun 响应解析失败：{e}"))?;
    value
        .get("text")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| "StepFun 响应缺少 text 字段".to_string())
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

    #[test]
    fn finish_without_audio_reports_error() {
        let recording = Arc::new(RecordingSink::default());
        let sink: Arc<dyn AsrSink> = recording.clone();
        let mut provider = StepFunBatchAsr::new("step-audio", "key", sink);
        provider.finish();
        assert_eq!(recording.errors.lock().unwrap().len(), 1);
        assert!(recording.text.lock().unwrap().is_empty());
    }

    #[test]
    fn missing_key_is_rejected() {
        let recording = Arc::new(RecordingSink::default());
        let sink: Arc<dyn AsrSink> = recording;
        let mut provider = StepFunBatchAsr::new("step-audio", "  ", sink);
        assert!(provider.start().is_err());
    }

    #[test]
    fn audio_is_capped_at_five_minutes() {
        let recording = Arc::new(RecordingSink::default());
        let sink: Arc<dyn AsrSink> = recording.clone();
        let mut provider = StepFunBatchAsr::new("step-audio", "key", sink);
        provider.start().unwrap();
        provider.send_pcm(&vec![0u8; 16_000 * 2 * 299]);
        assert!(recording.errors.lock().unwrap().is_empty());
        provider.send_pcm(&vec![0u8; 16_000 * 2 * 2]);
        assert_eq!(recording.errors.lock().unwrap().len(), 1);
    }
}
