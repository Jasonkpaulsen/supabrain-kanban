//! Windows platform backend (CIP-094).
//! System-audio capture uses WASAPI loopback on the default render endpoint (whole-system mix).

use super::audio::{AudioBackend, AudioDevice, CaptureBackends, CaptureHandle, LiveCaptureConfig};
use super::{fs::StdVaultFs, fs::VaultFs, Platform, PlatformError, Result};

pub struct WindowsPlatform {
    audio: WasapiAudio,
    fs: StdVaultFs,
}
impl WindowsPlatform {
    pub fn new() -> Self {
        Self { audio: WasapiAudio, fs: StdVaultFs::new() }
    }
}
impl Platform for WindowsPlatform {
    fn name(&self) -> &'static str { "windows" }
    fn audio(&self) -> &dyn AudioBackend { &self.audio }
    fn fs(&self) -> &dyn VaultFs { &self.fs }
}

pub struct WasapiAudio;

impl AudioBackend for WasapiAudio {
    fn backends(&self) -> CaptureBackends {
        CaptureBackends {
            system_audio: "WASAPI loopback".into(),
            microphone: "WASAPI capture".into(),
        }
    }

    fn list_input_devices(&self) -> Result<Vec<AudioDevice>> {
        // TODO(CIP-150): enumerate via IMMDeviceEnumerator (eCapture). Stubbed for the scaffold.
        Ok(vec![AudioDevice {
            id: "default".into(),
            name: "Default microphone".into(),
            is_default: true,
        }])
    }

    fn start_live(&self, _cfg: LiveCaptureConfig) -> Result<Box<dyn CaptureHandle>> {
        // TODO(CIP-150): open a WASAPI loopback client on the default render endpoint for the
        // system mix, plus a WASAPI capture client for the mic; mix/interleave to WAV with rolling
        // chunked autosave; report peak level. Return a handle whose stop() finalizes into the vault.
        Err(PlatformError::Unsupported(
            "WASAPI loopback capture not yet implemented (CIP-150)".into(),
        ))
    }
}
