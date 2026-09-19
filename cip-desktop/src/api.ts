// Typed wrappers over the Tauri command surface (src-tauri/src/commands.rs).
import { invoke } from "@tauri-apps/api/core";

export type AudioDevice = { id: string; name: string; is_default: boolean };
export type CaptureBackends = { system_audio: string; microphone: string };
export type Session = {
  id: string;
  session_number: number;
  title: string | null;
  source: "live" | "upload";
  recorded_at: string;
  status: string;
};

export const api = {
  captureBackends: () => invoke<CaptureBackends>("capture_backends"),
  listInputDevices: () => invoke<AudioDevice[]>("list_input_devices"),
  liveCaptureAvailable: () => invoke<boolean>("live_capture_available"),

  createCampaign: (campaign_id: string, name: string, game_system: string | null) =>
    invoke<string>("create_campaign", { campaignId: campaign_id, name, gameSystem: game_system }),

  nextSessionNumber: (campaign_id: string) =>
    invoke<number>("next_session_number", { campaignId: campaign_id }),

  createSession: (
    campaign_id: string,
    session_number: number,
    title: string | null,
    source: "live" | "upload",
    recorded_at: string,
  ) =>
    invoke<string>("create_session", {
      campaignId: campaign_id,
      sessionNumber: session_number,
      title,
      source,
      recordedAt: recorded_at,
    }),

  listSessions: (campaign_id: string) =>
    invoke<Session[]>("list_sessions", { campaignId: campaign_id }),
};

// Detect whether we're running inside the Tauri shell (vs. a plain browser dev preview).
export const inTauri = () => "__TAURI_INTERNALS__" in window;
