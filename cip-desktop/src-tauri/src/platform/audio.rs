//! Audio capture abstraction (CIP-094 audio seam, ADR-CIP system-wide capture, CIP-150/CIP-152).
//!
//! Two live streams: whole-system output MIX (any application) + the selected microphone.
//! This is NOT per-application isolation — it captures whatever the system is currently playing,
//! like the ChatGPT desktop recorder. Per-OS backends:
//!   - Windows: WASAPI loopback on the default render endpoint
//!   - macOS:   ScreenCaptureKit (13+) / Core Audio process-tap (14.4+)
//!
//! The `CaptureSource` enum is the seam from CIP-152: a session's audio comes from either a
//! `Live` capture or an `Upload`, and both feed the identical downstream pipeline.

use serde::{Deserialize, Serialize};
use super::Result;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioDevice {
    pub id: String,
    pub name: String,
    pub is_default: bool,
}

/// How a session's audio was produced. Mirrors `sessions.source` in the vault schema.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum CaptureSource {
    Live,
    Upload,
}

/// What the UI shows about this host's capture capabilities.
#[derive(Debug, Clone, Serialize)]
pub struct CaptureBackends {
    /// Human-readable name of the system-audio backend, e.g. "WASAPI loopback".
    pub system_audio: String,
    /// Human-readable name of the mic backend.
    pub microphone: String,
}

/// Config for a live capture session.
#[derive(Debug, Clone, Deserialize)]
pub struct LiveCaptureConfig {
    /// Microphone device id (None = system default).
    pub mic_device_id: Option<String>,
    /// Whether to also capture the whole-system audio mix.
    pub capture_system_audio: bool,
    /// Where to write the finalized audio (vault-relative path is resolved by the caller).
    pub output_path: String,
}

/// A running capture the caller can stop.
pub trait CaptureHandle: Send {
    /// Current peak level 0.0..=1.0 for the UI meter.
    fn level(&self) -> f32;
    /// Stop and finalize into the vault. Returns duration in seconds.
    fn stop(self: Box<Self>) -> Result<f64>;
}

/// OS audio backend. One impl per platform (windows/macos), plus an Unsupported fallback.
pub trait AudioBackend: Send + Sync {
    fn backends(&self) -> CaptureBackends;
    fn list_input_devices(&self) -> Result<Vec<AudioDevice>>;
    /// Start a live capture: whole-system mix (if requested) + mic. Returns a handle to stop it.
    fn start_live(&self, cfg: LiveCaptureConfig) -> Result<Box<dyn CaptureHandle>>;
}

/// Fallback for platforms/OS versions without native system-audio capture.
pub struct UnsupportedAudio {
    what: &'static str,
}
impl UnsupportedAudio {
    pub fn new(what: &'static str) -> Self { Self { what } }
}
impl AudioBackend for UnsupportedAudio {
    fn backends(&self) -> CaptureBackends {
        CaptureBackends {
            system_audio: format!("unsupported ({})", self.what),
            microphone: format!("unsupported ({})", self.what),
        }
    }
    fn list_input_devices(&self) -> Result<Vec<AudioDevice>> { Ok(vec![]) }
    fn start_live(&self, _cfg: LiveCaptureConfig) -> Result<Box<dyn CaptureHandle>> {
        Err(super::PlatformError::Unsupported(format!(
            "live system-audio capture not available on {}",
            self.what
        )))
    }
}
