//! Filesystem / vault-location abstraction (CIP-094).
//!
//! One SQLite vault per campaign (ADR-CIP one-vault-per-campaign, CIP-025/CIP-158). This resolves
//! where campaign vaults live and how per-campaign asset paths are formed (vault-on-import, CIP-120).

use std::path::{Path, PathBuf};
use super::Result;

pub trait VaultFs: Send + Sync {
    /// Root directory that holds all campaign vaults (platform data dir).
    fn vaults_root(&self) -> PathBuf;

    /// Directory for a single campaign vault. Each campaign is a self-contained folder:
    ///   <root>/<campaign_id>/campaign.cipdb  (SQLite)
    ///   <root>/<campaign_id>/assets/...       (vault-on-import media/audio)
    fn campaign_dir(&self, campaign_id: &str) -> PathBuf {
        self.vaults_root().join(campaign_id)
    }
    fn vault_db_path(&self, campaign_id: &str) -> PathBuf {
        self.campaign_dir(campaign_id).join("campaign.cipdb")
    }
    fn assets_dir(&self, campaign_id: &str) -> PathBuf {
        self.campaign_dir(campaign_id).join("assets")
    }

    /// Ensure the campaign directory structure exists.
    fn ensure_campaign_dirs(&self, campaign_id: &str) -> Result<()> {
        std::fs::create_dir_all(self.assets_dir(campaign_id))?;
        Ok(())
    }
}

/// Standard implementation using the OS data directory.
pub struct StdVaultFs {
    root: PathBuf,
}
impl StdVaultFs {
    pub fn new() -> Self {
        // In a real build this comes from tauri::path (app_data_dir). Kept dependency-light here.
        let base = std::env::var("CIP_DATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| default_data_dir());
        Self { root: base.join("campaigns") }
    }
}
impl VaultFs for StdVaultFs {
    fn vaults_root(&self) -> PathBuf { self.root.clone() }
}

fn default_data_dir() -> PathBuf {
    // Minimal per-OS default; the Tauri path API replaces this in the wired app.
    if let Ok(home) = std::env::var("HOME") {
        return Path::new(&home).join(".cip");
    }
    if let Ok(appdata) = std::env::var("APPDATA") {
        return Path::new(&appdata).join("CIP");
    }
    PathBuf::from(".cip")
}
