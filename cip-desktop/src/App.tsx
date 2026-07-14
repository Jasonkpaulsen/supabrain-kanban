import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { NAV } from "./nav";

type AudioDevice = { id: string; name: string; is_default: boolean };
type CaptureBackends = { system_audio: string; microphone: string };

export default function App() {
  const [active, setActive] = useState("dashboard");
  const [mics, setMics] = useState<AudioDevice[]>([]);
  const [backends, setBackends] = useState<CaptureBackends | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    // Probe the platform-abstraction layer (CIP-094) so the shell reflects real capabilities.
    invoke<CaptureBackends>("capture_backends").then(setBackends).catch((e) => setErr(String(e)));
    invoke<AudioDevice[]>("list_input_devices").then(setMics).catch(() => setMics([]));
  }, []);

  return (
    <div className="app">
      <nav className="sidebar">
        <div className="brand">CIP</div>
        {NAV.map((g) => (
          <div key={g.id} className="nav-group">
            <div className="nav-group-label">{g.label}</div>
            {g.items.map((it) => (
              <button
                key={it.id}
                className={"nav-item" + (active === it.id ? " active" : "")}
                onClick={() => setActive(it.id)}
              >
                {it.label}
                {it.badge ? <span className="badge">0</span> : null}
              </button>
            ))}
          </div>
        ))}
      </nav>

      <main className="content">
        <h1>Campaign Intelligence Platform</h1>
        <p className="muted">Local-first · one vault per campaign · offline-first.</p>

        <section className="card">
          <h2>Capture backends (platform layer)</h2>
          {err && <p className="error">{err}</p>}
          {backends ? (
            <ul>
              <li>System audio: <code>{backends.system_audio}</code></li>
              <li>Microphone: <code>{backends.microphone}</code></li>
            </ul>
          ) : (
            <p className="muted">probing…</p>
          )}
          <p className="muted">
            System-wide capture (any application) + mic — per ADR-CIP. OS backends are stubbed
            until CIP-150 lands the native implementations.
          </p>
        </section>

        <section className="card">
          <h2>Input devices</h2>
          {mics.length ? (
            <ul>{mics.map((m) => <li key={m.id}>{m.name}{m.is_default ? " (default)" : ""}</li>)}</ul>
          ) : (
            <p className="muted">No input devices reported by the platform layer.</p>
          )}
        </section>
      </main>
    </div>
  );
}
