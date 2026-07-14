//! Platform abstraction layer (CIP-094).
//!
//! Isolates every OS-specific concern — audio capture, filesystem/vault location, and (later)
//! GPU/model-runtime selection — behind clean traits so the rest of the app is platform-agnostic.
//! The concrete backend is chosen at compile time via `cfg(target_os = ...)`.

pub mod audio;
pub mod fs;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "macos")]
mod macos;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum PlatformError {
    #[error("capability not supported on this platform/OS version: {0}")]
    Unsupported(String),
    #[error("permission denied: {0}")]
    PermissionDenied(String),
    #[error("audio backend error: {0}")]
    Audio(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, PlatformError>;

/// The set of platform capabilities the app depends on. One implementation per OS.
pub trait Platform: Send + Sync {
    fn name(&self) -> &'static str;
    fn audio(&self) -> &dyn audio::AudioBackend;
    fn fs(&self) -> &dyn fs::VaultFs;
}

/// Resolve the platform implementation for the host OS.
pub fn current() -> Box<dyn Platform> {
    #[cfg(target_os = "windows")]
    {
        Box::new(windows::WindowsPlatform::new())
    }
    #[cfg(target_os = "macos")]
    {
        Box::new(macos::MacosPlatform::new())
    }
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    {
        Box::new(fallback::FallbackPlatform::new())
    }
}

/// Portable fallback (Linux/dev) — filesystem works; native audio capture is unsupported.
#[cfg(not(any(target_os = "windows", target_os = "macos")))]
mod fallback {
    use super::*;

    pub struct FallbackPlatform {
        audio: audio::UnsupportedAudio,
        fs: fs::StdVaultFs,
    }
    impl FallbackPlatform {
        pub fn new() -> Self {
            Self { audio: audio::UnsupportedAudio::new("this OS"), fs: fs::StdVaultFs::new() }
        }
    }
    impl Platform for FallbackPlatform {
        fn name(&self) -> &'static str { "fallback" }
        fn audio(&self) -> &dyn audio::AudioBackend { &self.audio }
        fn fs(&self) -> &dyn fs::VaultFs { &self.fs }
    }
}
