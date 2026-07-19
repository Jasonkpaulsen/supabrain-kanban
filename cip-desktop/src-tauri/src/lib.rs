//! CIP desktop core library (Tauri 2). Wires the platform layer + vault into the app and
//! exposes the IPC commands.

pub mod commands;
pub mod platform;
pub mod vault;

use platform::Platform;

/// App-wide state managed by Tauri and injected into commands.
pub struct AppState {
    pub platform: Box<dyn Platform>,
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(AppState { platform: platform::current() })
        .invoke_handler(tauri::generate_handler![
            commands::capture_backends,
            commands::list_input_devices,
            commands::create_campaign,
            commands::next_session_number,
            commands::create_session,
            commands::list_sessions,
            commands::live_capture_available,
        ])
        .run(tauri::generate_context!())
        .expect("error while running the CIP desktop app");
}
