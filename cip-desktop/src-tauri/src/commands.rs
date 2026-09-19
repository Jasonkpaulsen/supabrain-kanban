//! Tauri commands — the IPC surface the React UI calls.

use crate::platform::audio::{AudioDevice, CaptureBackends, CaptureSource};
use crate::vault::Session;
use crate::AppState;
use tauri::State;

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

/// Report the host's capture backends (drives the UI capability panel).
#[tauri::command]
pub fn capture_backends(state: State<AppState>) -> CaptureBackends {
    state.platform.audio().backends()
}

/// Enumerate microphone input devices (system audio needs no device pick — it's the whole mix).
#[tauri::command]
pub fn list_input_devices(state: State<AppState>) -> Result<Vec<AudioDevice>, String> {
    state.platform.audio().list_input_devices().map_err(err)
}

/// Create the campaign anchor in a fresh vault (one vault per campaign).
#[tauri::command]
pub fn create_campaign(
    state: State<AppState>,
    campaign_id: String,
    name: String,
    game_system: Option<String>,
) -> Result<String, String> {
    state.platform.fs().ensure_campaign_dirs(&campaign_id).map_err(err)?;
    let db = state.platform.fs().vault_db_path(&campaign_id);
    let vault = crate::vault::Vault::open(&db).map_err(err)?;
    let c = vault.init_campaign(&name, game_system.as_deref()).map_err(err)?;
    Ok(c.id)
}

/// Suggest the next session number for the Record Session control panel (CIP-149).
#[tauri::command]
pub fn next_session_number(state: State<AppState>, campaign_id: String) -> Result<f64, String> {
    let db = state.platform.fs().vault_db_path(&campaign_id);
    crate::vault::Vault::open(&db).map_err(err)?.next_session_number().map_err(err)
}

/// Create a session row for either a live capture or an uploaded file (CIP-152 source seam).
#[tauri::command]
pub fn create_session(
    state: State<AppState>,
    campaign_id: String,
    session_number: f64,
    title: Option<String>,
    source: String, // "live" | "upload"
    recorded_at: String,
) -> Result<String, String> {
    // validate the source against the capture-source enum
    let _src: CaptureSource = match source.as_str() {
        "live" => CaptureSource::Live,
        "upload" => CaptureSource::Upload,
        other => return Err(format!("invalid source: {other}")),
    };
    let db = state.platform.fs().vault_db_path(&campaign_id);
    let vault = crate::vault::Vault::open(&db).map_err(err)?;
    let s = vault
        .create_session(session_number, title.as_deref(), &source, &recorded_at)
        .map_err(err)?;
    Ok(s.id)
}

/// List a campaign's sessions, ordered for cataloguing (CIP-149).
#[tauri::command]
pub fn list_sessions(state: State<AppState>, campaign_id: String) -> Result<Vec<Session>, String> {
    let db = state.platform.fs().vault_db_path(&campaign_id);
    crate::vault::Vault::open(&db).map_err(err)?.list_sessions().map_err(err)
}

/// Whether native live (system-audio) capture is available on this host yet (CIP-150).
#[tauri::command]
pub fn live_capture_available(state: State<AppState>) -> bool {
    // Native backends are stubbed; probe by attempting a no-op start config.
    state
        .platform
        .audio()
        .start_live(crate::platform::audio::LiveCaptureConfig {
            mic_device_id: None,
            capture_system_audio: true,
            output_path: String::new(),
        })
        .is_ok()
}
