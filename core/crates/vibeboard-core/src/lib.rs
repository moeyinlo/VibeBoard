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
//!
//! The orchestration/ASR layers land in the next milestone.

pub mod auth;
pub mod discovery;
pub mod link;
pub mod opus;
pub mod protocol;

/// Device USB identity used by the firmware (ESP32 USB-JTAG/serial).
pub const DEVICE_VID: u16 = 0x303A;
pub const DEVICE_PID: u16 = 0x1001;
