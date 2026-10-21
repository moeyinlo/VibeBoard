//! Speech recognition providers.
//!
//! All providers consume 16 kHz mono PCM16, so the session layer decodes the device's Opus
//! frames exactly once and hands the same PCM to whichever provider is selected.

pub mod stepfun_batch;
pub mod stepfun_stream;

use std::sync::Arc;

/// Provider results are delivered on the provider's worker thread.
pub trait AsrSink: Send + Sync + 'static {
    /// `is_final == false` means a revised partial transcript.
    fn on_text(&self, text: &str, is_final: bool);
    fn on_error(&self, message: &str);
}

pub trait AsrProvider: Send {
    fn name(&self) -> &'static str;
    /// Starts connecting. Transport failures are reported through [`AsrSink::on_error`].
    fn start(&mut self) -> Result<(), String>;
    fn send_pcm(&mut self, pcm16: &[u8]);
    /// Flushes buffered audio and asks the provider for a final transcript.
    fn finish(&mut self);
    /// Aborts immediately; safe to call at any time.
    fn stop(&mut self);
}

pub const SAMPLE_RATE: u32 = 16_000;

/// Wraps PCM16 in a RIFF/WAVE container (mono, 16-bit) for batch endpoints.
pub fn wav_from_pcm16(pcm: &[u8], sample_rate: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(44 + pcm.len());
    let data_len = pcm.len() as u32;
    let byte_rate = sample_rate * 2;
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes()); // block align
    out.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    out.extend_from_slice(pcm);
    out
}

/// Shared sink adapter so the session layer can receive provider events through one channel.
pub type SharedSink = Arc<dyn AsrSink>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wav_header_is_well_formed() {
        let pcm = vec![0u8; 320];
        let wav = wav_from_pcm16(&pcm, 16_000);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(wav[4..8].try_into().unwrap()), 36 + 320);
        assert_eq!(&wav[8..16], b"WAVEfmt ");
        assert_eq!(u32::from_le_bytes(wav[16..20].try_into().unwrap()), 16);
        assert_eq!(u16::from_le_bytes(wav[20..22].try_into().unwrap()), 1);
        assert_eq!(u16::from_le_bytes(wav[22..24].try_into().unwrap()), 1);
        assert_eq!(u32::from_le_bytes(wav[24..28].try_into().unwrap()), 16_000);
        assert_eq!(u32::from_le_bytes(wav[28..32].try_into().unwrap()), 32_000);
        assert_eq!(&wav[36..40], b"data");
        assert_eq!(u32::from_le_bytes(wav[40..44].try_into().unwrap()), 320);
        assert_eq!(wav.len(), 44 + 320);
    }
}
