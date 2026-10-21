//! Locating the VibeBoard CDC interface.
//!
//! The firmware exposes an ESP32 USB-JTAG/serial unit (`303A:1001`). Its USB serial number
//! is the device MAC, which is also the registration identifier used by the vendor app.
//!
//! `serialport` already normalises IOKit (macOS) and SetupAPI (Windows) behind one API, so
//! only the selection policy lives here — the platform-specific discovery comes for free.

use serialport::{SerialPortInfo, SerialPortType};

use crate::{DEVICE_PID, DEVICE_VID};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DevicePresence {
    /// OS device path: `/dev/cu.usbmodem...` on macOS, `COM5` on Windows.
    pub port_name: String,
    /// USB serial number; the device MAC, used as the registration `mac`.
    pub serial: String,
    pub product: Option<String>,
    pub vendor_id: u16,
    pub product_id: u16,
}

impl DevicePresence {
    /// Serial numbers shaped like a MAC address are the ones the firmware provisions.
    pub fn looks_like_mac_serial(&self) -> bool {
        self.serial.contains(':')
            || (self.serial.len() == 12 && self.serial.chars().all(|c| c.is_ascii_hexdigit()))
    }
}

/// Picks the best matching port from a port list. Preference order:
/// 1. matching VID/PID with a MAC-shaped serial number
/// 2. matching VID/PID with any serial number
pub fn select_port(ports: &[SerialPortInfo]) -> Option<DevicePresence> {
    let candidates: Vec<DevicePresence> = ports
        .iter()
        .filter_map(|port| match &port.port_type {
            SerialPortType::UsbPort(info) if info.vid == DEVICE_VID && info.pid == DEVICE_PID => {
                Some(DevicePresence {
                    port_name: port.port_name.clone(),
                    serial: info.serial_number.clone().unwrap_or_default(),
                    product: info.product.clone(),
                    vendor_id: info.vid,
                    product_id: info.pid,
                })
            }
            _ => None,
        })
        .collect();

    candidates
        .iter()
        .find(|candidate| candidate.looks_like_mac_serial())
        .or_else(|| candidates.first())
        .cloned()
}

pub fn find_device() -> Result<Option<DevicePresence>, serialport::Error> {
    let ports = serialport::available_ports()?;
    Ok(select_port(&ports))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serialport::UsbPortInfo;

    fn usb_port(name: &str, vid: u16, pid: u16, serial: Option<&str>) -> SerialPortInfo {
        SerialPortInfo {
            port_name: name.to_string(),
            port_type: SerialPortType::UsbPort(UsbPortInfo {
                vid,
                pid,
                serial_number: serial.map(ToOwned::to_owned),
                manufacturer: Some("Espressif".into()),
                product: Some("USB JTAG/serial debug unit".into()),
            }),
        }
    }

    #[test]
    fn ignores_other_usb_devices() {
        let ports = vec![
            usb_port("/dev/cu.usbmodem123", 0x2341, 0x0043, Some("ABC")),
            SerialPortInfo {
                port_name: "/dev/cu.Bluetooth-Incoming-Port".into(),
                port_type: SerialPortType::Unknown,
            },
        ];
        assert!(select_port(&ports).is_none());
    }

    #[test]
    fn prefers_mac_shaped_serial() {
        let ports = vec![
            usb_port("COM7", DEVICE_VID, DEVICE_PID, Some("5&1a2b3c&0&2")),
            usb_port("COM5", DEVICE_VID, DEVICE_PID, Some("DC:A6:32:00:00:01")),
        ];
        let selected = select_port(&ports).unwrap();
        assert_eq!(selected.port_name, "COM5");
        assert!(selected.looks_like_mac_serial());
    }

    #[test]
    fn falls_back_to_single_candidate_without_serial() {
        let ports = vec![usb_port(
            "/dev/cu.usbmodem1101",
            DEVICE_VID,
            DEVICE_PID,
            None,
        )];
        let selected = select_port(&ports).unwrap();
        assert_eq!(selected.port_name, "/dev/cu.usbmodem1101");
        assert!(!selected.looks_like_mac_serial());
    }
}
