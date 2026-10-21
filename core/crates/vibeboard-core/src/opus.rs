//! Device audio: Opus packets -> 16 kHz mono signed 16-bit PCM.
//!
//! Mirrors the macOS client: the firmware sends one Opus packet per 20 ms audio frame and
//! the decoder is created directly at the device sample rate, so no resampling is needed.

use audiopus::coder::{Decoder, GenericCtl};
use audiopus::{Channels, SampleRate};

pub const SAMPLE_RATE: u32 = 16_000;
pub const CHANNELS: u8 = 1;
/// Maximum samples in a single packet (120 ms at 16 kHz) — the Opus upper bound.
pub const MAX_SAMPLES_PER_PACKET: usize = 5760;

#[derive(Debug)]
pub struct OpusPcmDecoder {
    decoder: Decoder,
    buffer: Vec<i16>,
    packets: u64,
    samples: u64,
    failures: u64,
}

impl OpusPcmDecoder {
    pub fn new() -> Result<Self, audiopus::Error> {
        Ok(Self {
            decoder: Decoder::new(SampleRate::Hz16000, Channels::Mono)?,
            buffer: vec![0; MAX_SAMPLES_PER_PACKET],
            packets: 0,
            samples: 0,
            failures: 0,
        })
    }

    pub fn reset(&mut self) {
        let _ = self.decoder.reset_state();
    }

    pub fn packets(&self) -> u64 {
        self.packets
    }

    pub fn failures(&self) -> u64 {
        self.failures
    }

    pub fn decoded_samples(&self) -> u64 {
        self.samples
    }

    /// Decodes one Opus packet. Empty packets (the device's "end of audio" marker) yield no PCM.
    pub fn decode(&mut self, packet: &[u8]) -> Result<&[i16], audiopus::Error> {
        if packet.is_empty() {
            return Ok(&[]);
        }
        match self.decoder.decode(Some(packet), &mut self.buffer, false) {
            Ok(count) => {
                self.packets += 1;
                self.samples += count as u64;
                Ok(&self.buffer[..count])
            }
            Err(error) => {
                self.failures += 1;
                Err(error)
            }
        }
    }

    /// Decodes and returns little-endian PCM16 bytes, ready for the ASR providers.
    pub fn decode_to_pcm16(&mut self, packet: &[u8]) -> Result<Vec<u8>, audiopus::Error> {
        let samples = self.decode(packet)?;
        let mut bytes = Vec::with_capacity(samples.len() * 2);
        for sample in samples {
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use audiopus::coder::Encoder;
    use audiopus::Application;

    fn encode_tone(samples: usize) -> Vec<Vec<u8>> {
        let encoder = Encoder::new(SampleRate::Hz16000, Channels::Mono, Application::Voip).unwrap();
        let pcm: Vec<i16> = (0..samples)
            .map(|i| {
                ((i as f32 * 2.0 * std::f32::consts::PI * 440.0 / 16_000.0).sin() * 8_000.0) as i16
            })
            .collect();
        let mut packet = vec![0u8; 4000];
        let len = encoder.encode(&pcm[..], &mut packet).unwrap();
        packet.truncate(len);
        vec![packet]
    }

    #[test]
    fn decodes_one_20ms_frame_to_320_samples() {
        let packets = encode_tone(320);
        let mut decoder = OpusPcmDecoder::new().unwrap();
        let samples = decoder.decode(&packets[0]).unwrap();
        assert_eq!(samples.len(), 320);
        assert_eq!(decoder.packets(), 1);
        assert_eq!(decoder.decoded_samples(), 320);
    }

    #[test]
    fn empty_packet_is_a_no_op() {
        let mut decoder = OpusPcmDecoder::new().unwrap();
        assert!(decoder.decode(&[]).unwrap().is_empty());
        assert_eq!(decoder.packets(), 0);
    }

    #[test]
    fn pcm16_output_is_little_endian() {
        let packets = encode_tone(320);
        let mut decoder = OpusPcmDecoder::new().unwrap();
        let bytes = decoder.decode_to_pcm16(&packets[0]).unwrap();
        assert_eq!(bytes.len(), 640);
    }

    #[test]
    fn invalid_packet_counts_as_failure() {
        let mut decoder = OpusPcmDecoder::new().unwrap();
        assert!(decoder.decode(&[0xff, 0xff, 0xff]).is_err());
        assert_eq!(decoder.failures(), 1);
    }
}
