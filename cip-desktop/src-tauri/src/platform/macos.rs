//! macOS platform backend (CIP-094).
//! System-audio capture uses ScreenCaptureKit (macOS 13+) or a Core Audio process-tap (14.4+) for
//! driver-free whole-system capture — the same approach the ChatGPT desktop app uses.

use super::audio::{AudioBackend, AudioDevice, CaptureBackends, CaptureHandle, LiveCaptureConfig};
use super::{fs::StdVaultFs, fs::VaultFs, Platform, PlatformError, Result};

pub struct MacosPlatform {
    audio: ScreenCaptureAudio,
    fs: StdVaultFs,
}
impl MacosPlatform {
    pub fn new() -> Self {
        Self { audio: ScreenCaptureAudio, fs: StdVaultFs::new() }
    }
}
impl Platform for MacosPlatform {
    fn name(&self) -> &'static str { "macos" }
    fn audio(&self) -> &dyn AudioBackend { &self.audio }
    fn fs(&self) -> &dyn VaultFs { &self.fs }
}

pub struct ScreenCaptureAudio;

impl AudioBackend for ScreenCaptureAudio {
    fn backends(&self) -> CaptureBackends {
        CaptureBackends {
            system_audio: "ScreenCaptureKit / Core Audio tap".into(),
            microphone: "AVAudioEngine / Core Audio".into(),
        }
    }

    fn list_input_devices(&self) -> Result<Vec<AudioDevice>> {
        // TODO(CIP-150): enumerate via Core Audio (kAudioHardwarePropertyDevices). Stubbed.
        Ok(vec![AudioDevice {
            id: "default".into(),
            name: "Default microphone".into(),
            is_default: true,
        }])
    }

    fn start_live(&self, _cfg: LiveCaptureConfig) -> Result<Box<dyn CaptureHandle>> {
        // TODO(CIP-150): request screen/audio-recording permission; start an SCStream capturing the
        // system audio mix (SCContentFilter over displays), plus the mic; write to WAV with rolling
        // chunked autosave. On < macOS 13, fall back to a bundled virtual audio device.
        Err(PlatformError::Unsupported(
            "ScreenCaptureKit system-audio capture not yet implemented (CIP-150)".into(),
        ))
    }
}
