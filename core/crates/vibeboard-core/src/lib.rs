//! VibeBoard shared core: USB/serial device protocol, device auth, ASR providers and
//! session orchestration. Deliberately free of UI toolkits so that the macOS (Swift/AppKit)
//! and Windows (C#/WPF) shells can both drive it through the C ABI in [`ffi`].
//!
//! Layout:
//! - [`protocol`] framing, JSON events and device commands (pure, unit-tested)
//! - [`discovery`] locating the VibeBoard CDC interface on the current host
//! - [`link`] serial link: handshake, heartbeat, device_info polling, reconnect
//! - [`auth`] `/v1/device/register` and `/v1/device/token` (HMAC-SHA256)
//! - [`opus`] device Opus frame -> 16 kHz mono PCM
//! - [`asr`] StepFun streaming/batch recognition (external and Whisper providers next)
//! - [`session`] button semantics, session lifecycle and output routing
//! - [`rewrite`] light semantic cleanup through StepFun chat completions
//! - [`app`] discovery loop, provisioning and wiring into the session machine

pub mod app;
pub mod asr;
pub mod auth;
pub mod button;
pub mod discovery;
pub mod link;
pub mod opus;
pub mod protocol;
pub mod rewrite;
pub mod session;

/// Device USB identity used by the firmware (ESP32 USB-JTAG/serial).
pub const DEVICE_VID: u16 = 0x303A;
pub const DEVICE_PID: u16 = 0x1001;
