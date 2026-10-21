//! Wire protocol for the VibeBoard USB CDC link.
//!
//! Frame shape (reverse engineered from the vendor app, verified on hardware):
//!
//! ```text
//! [0x01][type:u8][len:u16 LE][payload:len]
//! ```
//!
//! - `type = 0x01` audio: the 16-byte "payload" is an audio header, and the real Opus
//!   payload length is stored inside it:
//!
//!   ```text
//!   [0]=0x01 [1]=0x01 [2..4]=16 LE [4..8]=session u32 LE
//!   [8..12]=sequence u32 LE [12]=flags [13]=reserved [14..16]=audio_len u16 LE
//!   ```
//!
//! - `type = 0x10` state: JSON body (`device_info`, `button_*`, `provision_ack`, ...)
//! - `type = 0x30` OTA status: opaque to this client
//!
//! Host -> device commands are JSON state frames: `transport`, `transport_ready`, `ping`,
//! `get_device_info`, `ready`, `ui_state`, `provision`.

use serde::{Deserialize, Serialize};
use serde_json::json;

pub const HEADER: u8 = 0x01;
pub const TYPE_AUDIO: u8 = 0x01;
pub const TYPE_STATE: u8 = 0x10;
pub const TYPE_OTA: u8 = 0x30;

/// Upper bound accepted for any frame payload. Anything larger is treated as a resync point.
pub const MAX_FRAME_LEN: usize = 4096;

/// Byte offset of the audio payload length inside the 16-byte audio header.
const AUDIO_HEADER_LEN: u8 = 16;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioFrame {
    pub session_id: u32,
    pub sequence: u32,
    pub flags: u8,
    pub payload: Vec<u8>,
}

impl AudioFrame {
    /// Bit 0x02 marks the final frame of a recording.
    pub fn is_last(&self) -> bool {
        self.flags & 0x02 != 0
    }

    /// Parses a complete `16 + payload_len` byte audio frame.
    pub fn parse(data: &[u8]) -> Option<Self> {
        if data.len() < 16 || data[0] != HEADER || data[1] != TYPE_AUDIO {
            return None;
        }
        if u16::from_le_bytes([data[2], data[3]]) != AUDIO_HEADER_LEN as u16 {
            return None;
        }
        let payload_len = u16::from_le_bytes([data[14], data[15]]) as usize;
        if payload_len > MAX_FRAME_LEN || data.len() != 16 + payload_len {
            return None;
        }
        Some(Self {
            session_id: u32::from_le_bytes([data[4], data[5], data[6], data[7]]),
            sequence: u32::from_le_bytes([data[8], data[9], data[10], data[11]]),
            flags: data[12],
            payload: data[16..].to_vec(),
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Incoming {
    /// Device microphone audio (Opus).
    Audio(AudioFrame),
    /// Parsed JSON state event.
    State(serde_json::Value),
    /// Bytes that are not part of a known frame; may be raw device text.
    Raw(Vec<u8>),
}

impl Incoming {
    pub fn as_text(&self) -> Option<String> {
        match self {
            Incoming::Raw(bytes) => std::str::from_utf8(bytes).ok().map(ToOwned::to_owned),
            _ => None,
        }
    }
}

/// Incremental frame parser. Feed arbitrary chunks; incomplete frames stay buffered.
#[derive(Debug, Default)]
pub struct FrameParser {
    pending: Vec<u8>,
}

impl FrameParser {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn buffered(&self) -> usize {
        self.pending.len()
    }

    pub fn reset(&mut self) {
        self.pending.clear();
    }

    pub fn feed(&mut self, data: &[u8]) -> Vec<Incoming> {
        self.pending.extend_from_slice(data);
        let mut out = Vec::new();

        loop {
            let Some(start) = self.pending.iter().position(|&b| b == HEADER) else {
                if !self.pending.is_empty() {
                    out.push(Incoming::Raw(std::mem::take(&mut self.pending)));
                }
                return out;
            };
            if start > 0 {
                let prefix: Vec<u8> = self.pending.drain(..start).collect();
                out.push(Incoming::Raw(prefix));
            }

            if self.pending.len() < 4 {
                return out;
            }
            let frame_type = self.pending[1];

            if frame_type == TYPE_AUDIO {
                if self.pending.len() < 16 {
                    return out;
                }
                if self.pending[2] != AUDIO_HEADER_LEN || self.pending[3] != 0 {
                    // Not a valid audio header: drop one byte and resync.
                    self.pending.remove(0);
                    continue;
                }
                let payload_len = u16::from_le_bytes([self.pending[14], self.pending[15]]) as usize;
                if payload_len > MAX_FRAME_LEN {
                    self.pending.remove(0);
                    continue;
                }
                if self.pending.len() < 16 + payload_len {
                    return out;
                }
                let total = 16 + payload_len;
                match AudioFrame::parse(&self.pending[..total]) {
                    Some(frame) => {
                        self.pending.drain(..total);
                        out.push(Incoming::Audio(frame));
                    }
                    None => {
                        self.pending.remove(0);
                    }
                }
                continue;
            }

            if frame_type != TYPE_STATE && frame_type != TYPE_OTA {
                // Unknown frame type: not a real boundary, drop one byte and resync. Without
                // this the parser can mistake garbage for a state frame and stall on its
                // bogus length.
                self.pending.remove(0);
                continue;
            }
            let len = u16::from_le_bytes([self.pending[2], self.pending[3]]) as usize;
            if len > MAX_FRAME_LEN {
                self.pending.remove(0);
                continue;
            }
            if self.pending.len() < 4 + len {
                return out;
            }
            let payload: Vec<u8> = self.pending[4..4 + len].to_vec();
            self.pending.drain(..4 + len);

            if frame_type == TYPE_STATE {
                match serde_json::from_slice::<serde_json::Value>(&payload) {
                    Ok(value) => out.push(Incoming::State(value)),
                    Err(_) => out.push(Incoming::Raw(payload)),
                }
            } else {
                out.push(Incoming::Raw(payload));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Device -> host JSON events
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DeviceInfo {
    #[serde(default)]
    pub device_id: String,
    #[serde(default)]
    pub hardware: String,
    #[serde(default)]
    pub firmware_version: String,
    #[serde(default)]
    pub provisioned: bool,
    #[serde(default)]
    pub buttons: Vec<String>,
    #[serde(default)]
    pub ui_states: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DeviceEvent {
    DeviceInfo(DeviceInfo),
    ButtonDown {
        button: String,
        session_id: u64,
    },
    ButtonUp {
        button: String,
        session_id: u64,
        duration_ms: u64,
    },
    ButtonClick {
        button: String,
        duration_ms: u64,
    },
    ProvisionAck {
        ok: bool,
        message: Option<String>,
    },
    /// Any other event (`device_error`, `pending_confirmation`, ...) kept for logging.
    Other(serde_json::Value),
}

impl DeviceEvent {
    /// Decodes a state frame JSON payload. Returns `None` when the event is not recognized
    /// and should only be logged.
    pub fn parse(value: &serde_json::Value) -> Option<DeviceEvent> {
        let event = value.get("event").or_else(|| value.get("type"))?.as_str()?;
        let button = value
            .get("button")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_lowercase();
        let session = value
            .get("session_id")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);
        let duration = value
            .get("duration_ms")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);

        Some(match event {
            "device_info" => DeviceEvent::DeviceInfo(serde_json::from_value(value.clone()).ok()?),
            "button_down" => DeviceEvent::ButtonDown {
                button,
                session_id: session,
            },
            "button_up" => DeviceEvent::ButtonUp {
                button,
                session_id: session,
                duration_ms: duration,
            },
            "button_click" => DeviceEvent::ButtonClick {
                button,
                duration_ms: duration,
            },
            "provision_ack" => DeviceEvent::ProvisionAck {
                ok: value
                    .get("status")
                    .and_then(|v| v.as_str())
                    .map(|s| s == "ok")
                    .or_else(|| value.get("ok").and_then(|v| v.as_bool()))
                    .unwrap_or_else(|| value.get("message").and_then(|v| v.as_str()) == Some("ok")),
                message: value
                    .get("message")
                    .or_else(|| value.get("status"))
                    .and_then(|v| v.as_str())
                    .map(ToOwned::to_owned),
            },
            _ => DeviceEvent::Other(value.clone()),
        })
    }
}

// ---------------------------------------------------------------------------
// Host -> device commands
// ---------------------------------------------------------------------------

pub fn frame(frame_type: u8, body: &[u8]) -> Vec<u8> {
    let len = body.len().min(u16::MAX as usize) as u16;
    let mut out = Vec::with_capacity(4 + body.len());
    out.push(HEADER);
    out.push(frame_type);
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(&body[..len as usize]);
    out
}

pub fn state_frame(body: &[u8]) -> Vec<u8> {
    frame(TYPE_STATE, body)
}

pub fn transport_frame() -> Vec<u8> {
    state_frame(br#"{"event":"transport","kind":"usb"}"#)
}

pub fn transport_ready_frame() -> Vec<u8> {
    state_frame(br#"{"event":"transport_ready","kind":"usb"}"#)
}

pub fn ping_frame() -> Vec<u8> {
    state_frame(br#"{"event":"ping"}"#)
}

pub fn get_device_info_frame() -> Vec<u8> {
    state_frame(br#"{"event":"get_device_info"}"#)
}

pub fn ready_frame(session_id: u64) -> Vec<u8> {
    state_frame(
        json!({ "event": "ready", "session_id": session_id })
            .to_string()
            .as_bytes(),
    )
}

pub fn ui_state_frame(state: &str, text: &str) -> Vec<u8> {
    state_frame(
        json!({ "event": "ui_state", "state": state, "text": text })
            .to_string()
            .as_bytes(),
    )
}

pub fn provision_frame(device_id: &str, secret: &str) -> Vec<u8> {
    state_frame(
        json!({ "event": "provision", "device_id": device_id, "device_secret": secret })
            .to_string()
            .as_bytes(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state_body(bytes: &[u8]) -> serde_json::Value {
        assert_eq!(bytes[0], HEADER);
        assert_eq!(bytes[1], TYPE_STATE);
        let len = u16::from_le_bytes([bytes[2], bytes[3]]) as usize;
        serde_json::from_slice(&bytes[4..4 + len]).unwrap()
    }

    #[test]
    fn state_frame_roundtrip() {
        let bytes = ui_state_frame("ready", "");
        assert_eq!(
            state_body(&bytes),
            json!({"event":"ui_state","state":"ready","text":""})
        );
    }

    #[test]
    fn ui_state_keeps_unicode_text() {
        let bytes = ui_state_frame("ready", "你好，世界");
        assert_eq!(state_body(&bytes)["text"], "你好，世界");
    }

    #[test]
    fn ready_and_provision_payloads() {
        assert_eq!(state_body(&ready_frame(42))["session_id"], 42);
        let provision = state_body(&provision_frame("dev-1", "s3cret"));
        assert_eq!(provision["event"], "provision");
        assert_eq!(provision["device_id"], "dev-1");
        assert_eq!(provision["device_secret"], "s3cret");
        for bytes in [
            transport_frame(),
            transport_ready_frame(),
            ping_frame(),
            get_device_info_frame(),
        ] {
            assert_eq!(bytes[0], HEADER);
            assert_eq!(bytes[1], TYPE_STATE);
        }
    }

    fn audio_frame_bytes(session: u32, seq: u32, flags: u8, payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.push(HEADER);
        out.push(TYPE_AUDIO);
        out.extend_from_slice(&(AUDIO_HEADER_LEN as u16).to_le_bytes());
        out.extend_from_slice(&session.to_le_bytes());
        out.extend_from_slice(&seq.to_le_bytes());
        out.push(flags);
        out.push(0);
        out.extend_from_slice(&(payload.len() as u16).to_le_bytes());
        out.extend_from_slice(payload);
        out
    }

    #[test]
    fn parses_audio_frame_and_last_flag() {
        let bytes = audio_frame_bytes(7, 3, 0x00, &[1, 2, 3, 4]);
        let parsed = AudioFrame::parse(&bytes).unwrap();
        assert_eq!(parsed.session_id, 7);
        assert_eq!(parsed.sequence, 3);
        assert_eq!(parsed.payload, vec![1, 2, 3, 4]);
        assert!(!parsed.is_last());

        let last = audio_frame_bytes(7, 4, 0x02, &[]);
        let parsed = AudioFrame::parse(&last).unwrap();
        assert!(parsed.is_last());
        assert!(parsed.payload.is_empty());
    }

    #[test]
    fn parser_handles_split_and_coalesced_frames() {
        let first = audio_frame_bytes(1, 0, 0, &[9; 40]);
        let second = audio_frame_bytes(1, 1, 0x02, &[]);
        let mut stream = first.clone();
        stream.extend_from_slice(&second);

        let mut parser = FrameParser::new();
        // Byte-by-byte should still yield both frames.
        let mut items = Vec::new();
        for byte in &stream {
            items.extend(parser.feed(&[*byte]));
        }
        assert_eq!(items.len(), 2);
        assert!(matches!(&items[0], Incoming::Audio(f) if f.payload.len() == 40));
        assert!(matches!(&items[1], Incoming::Audio(f) if f.is_last()));
    }

    #[test]
    fn parser_reports_raw_prefix_then_frame() {
        let mut stream = b"Rebooting...".to_vec();
        stream.extend_from_slice(&audio_frame_bytes(2, 0, 0, &[5; 8]));

        let mut parser = FrameParser::new();
        let items = parser.feed(&stream);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].as_text().as_deref(), Some("Rebooting..."));
        assert!(matches!(items[1], Incoming::Audio(_)));
    }

    #[test]
    fn parser_resyncs_on_invalid_audio_header() {
        let mut stream = vec![HEADER, TYPE_AUDIO, 0x00, 0x00];
        stream.extend_from_slice(&audio_frame_bytes(3, 0, 0, &[7; 4]));

        let mut parser = FrameParser::new();
        let items = parser.feed(&stream);
        assert!(items
            .iter()
            .any(|item| matches!(item, Incoming::Audio(f) if f.session_id == 3)));
    }

    #[test]
    fn parser_rejects_oversized_payload_and_recovers() {
        let mut broken = vec![HEADER, TYPE_STATE, 0xFF, 0xFF];
        broken.extend_from_slice(&audio_frame_bytes(4, 0, 0, &[1; 4]));

        let mut parser = FrameParser::new();
        let items = parser.feed(&broken);
        assert!(items
            .iter()
            .any(|item| matches!(item, Incoming::Audio(f) if f.session_id == 4)));
    }

    #[test]
    fn parser_parses_state_json_and_keeps_unknown_frames_raw() {
        let state = state_frame(br#"{"event":"button_down","button":"K4","session_id":9}"#);
        let ota = frame(TYPE_OTA, b"ota-bytes");

        let mut parser = FrameParser::new();
        let items = parser.feed(&[state, ota].concat());
        assert_eq!(items.len(), 2);
        let event = match &items[0] {
            Incoming::State(v) => DeviceEvent::parse(v).unwrap(),
            other => panic!("expected state, got {other:?}"),
        };
        assert_eq!(
            event,
            DeviceEvent::ButtonDown {
                button: "k4".into(),
                session_id: 9
            }
        );
        assert_eq!(items[1], Incoming::Raw(b"ota-bytes".to_vec()));
    }

    #[test]
    fn device_events_parse() {
        let info: serde_json::Value = serde_json::from_str(
            r#"{"event":"device_info","device_id":"VS-1","hardware":"vibe_keyboard",
                "firmware_version":"0.3.8","provisioned":true,"buttons":["k1"],"ui_states":["ready"]}"#,
        )
        .unwrap();
        match DeviceEvent::parse(&info).unwrap() {
            DeviceEvent::DeviceInfo(d) => {
                assert_eq!(d.device_id, "VS-1");
                assert_eq!(d.firmware_version, "0.3.8");
                assert!(d.provisioned);
            }
            other => panic!("unexpected {other:?}"),
        }

        let ack: serde_json::Value =
            serde_json::from_str(r#"{"event":"provision_ack","message":"ok"}"#).unwrap();
        assert_eq!(
            DeviceEvent::parse(&ack).unwrap(),
            DeviceEvent::ProvisionAck {
                ok: true,
                message: Some("ok".into())
            }
        );

        let up: serde_json::Value = serde_json::from_str(
            r#"{"event":"button_up","button":"k4","session_id":15,"duration_ms":1890}"#,
        )
        .unwrap();
        assert_eq!(
            DeviceEvent::parse(&up).unwrap(),
            DeviceEvent::ButtonUp {
                button: "k4".into(),
                session_id: 15,
                duration_ms: 1890
            }
        );

        let unknown: serde_json::Value =
            serde_json::from_str(r#"{"event":"device_error","code":3}"#).unwrap();
        assert!(matches!(
            DeviceEvent::parse(&unknown),
            Some(DeviceEvent::Other(_))
        ));
    }

    #[test]
    fn parser_keeps_incomplete_frame_buffered() {
        let bytes = audio_frame_bytes(5, 0, 0, &[1; 32]);
        let mut parser = FrameParser::new();
        let head = parser.feed(&bytes[..20]);
        assert!(head.is_empty());
        assert_eq!(parser.buffered(), 20);
        let tail = parser.feed(&bytes[20..]);
        assert_eq!(tail.len(), 1);
        assert_eq!(parser.buffered(), 0);
    }
}
