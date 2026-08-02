# CIP Desktop — Campaign Intelligence Platform (V1)

Local-first desktop app for TTRPG DMs: record/upload a session → transcribe + diarize →
extract entities → auto-maintained cross-linked campaign wiki. One-time purchase, offline-first.

This is the scaffold produced for **CIP-006** (Tauri + React app shell) and **CIP-094**
(platform-abstraction layer). It compiles the architecture decisions into real code:

| Decision (ADR) | Where it lives |
| --- | --- |
| One vault per campaign; `campaigns` single-row anchor (CIP-158) | `src-tauri/src/vault/` + `migrations/0001_init.sql` |
| TEXT-UUID primary keys everywhere (CIP-154) | `migrations/0001_init.sql` |
| System-wide audio capture (mixed) + mic, not per-app (CIP-150) | `src-tauri/src/platform/audio.rs` |
| Platform abstraction isolates OS-specific GPU/audio/fs (CIP-094) | `src-tauri/src/platform/` |
| Capture-source abstraction: Live \| Upload (CIP-152) | `src-tauri/src/platform/audio.rs` (`CaptureSource`) |
| Decimal `session_number`, editable `recorded_at`, ordering (CIP-149) | `migrations/0001_init.sql` |
| Grouped IA left-nav (CIP-123/141) | `src/nav.ts`, `src/App.tsx` |

## Stack
- **Tauri 2** (Rust core) + **React 18 + TypeScript + Vite** (UI)
- **rusqlite** (bundled SQLite) for the per-campaign vault
- Local model stack (Whisper / pyannote / Qwen) integrates via the platform layer — stubbed here.

## Status of the platform layer
The OS-specific system-audio capture backends are **defined as traits with typed stubs**:
- **Windows** → WASAPI loopback (`platform/windows.rs`)
- **macOS** → ScreenCaptureKit / Core Audio process-tap (`platform/macos.rs`)

These stubs return `Unsupported` until the native capture is implemented (tracked on CIP-150).
Everything else (vault, schema, commands, UI shell, capture-source seam) is real.

## Develop
```bash
cd cip-desktop
npm install
npm run tauri dev      # requires the Rust toolchain + Tauri prerequisites for your OS
```
Build a release bundle: `npm run tauri build`.

> Not yet split into its own repo. When the Worldwright entity is ready (see CIP epic
> "Form NY legal entity"), this directory is intended to be extracted to a dedicated repo.
