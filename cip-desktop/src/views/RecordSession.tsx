import { useEffect, useRef, useState } from "react";
import { api, inTauri, type AudioDevice, type CaptureBackends } from "../api";

type Mode = "live" | "upload";

// Record Session control panel (CIP-130 / CIP-153). Two modes: live capture vs. upload.
export default function RecordSession({
  campaignId,
  onSaved,
}: {
  campaignId: string;
  onSaved: () => void;
}) {
  const [mode, setMode] = useState<Mode>("live");
  const [backends, setBackends] = useState<CaptureBackends | null>(null);
  const [devices, setDevices] = useState<AudioDevice[]>([]);
  const [liveOk, setLiveOk] = useState(false);
  const [captureSystem, setCaptureSystem] = useState(true);
  const [mic, setMic] = useState<string>("default");

  // metadata
  const [title, setTitle] = useState("");
  const [num, setNum] = useState<number>(1);
  const [recordedAt, setRecordedAt] = useState<string>(() => localISO(new Date()));
  const [fileName, setFileName] = useState<string | null>(null);

  // live recording state (UI-only; native capture lands in CIP-150)
  const [recording, setRecording] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [level] = useState(0);
  const timer = useRef<number | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!inTauri()) return;
    api.captureBackends().then(setBackends).catch(() => {});
    api.listInputDevices().then(setDevices).catch(() => {});
    api.liveCaptureAvailable().then(setLiveOk).catch(() => setLiveOk(false));
    api.nextSessionNumber(campaignId).then(setNum).catch(() => {});
  }, [campaignId]);

  function toggleRecord() {
    if (!liveOk) {
      setMsg("Native system-audio capture isn't implemented yet (CIP-150). Use Upload for now, or run in a build with the capture backend.");
      return;
    }
    if (recording) {
      setRecording(false);
      if (timer.current) window.clearInterval(timer.current);
    } else {
      setRecording(true);
      setElapsed(0);
      timer.current = window.setInterval(() => setElapsed((e) => e + 1), 1000);
    }
  }

  async function save() {
    setErr(null);
    try {
      if (inTauri()) {
        await api.createSession(campaignId, num, title.trim() || null, mode, toUTC(recordedAt));
      }
      setMsg(`Saved session ${num.toFixed(1)}${title ? ` — ${title}` : ""}.`);
      setTitle("");
      if (inTauri()) api.nextSessionNumber(campaignId).then(setNum).catch(() => {});
      onSaved();
    } catch (e) {
      setErr(String(e));
    }
  }

  return (
    <div>
      <h1>Record Session</h1>
      <div className="seg">
        <button className={mode === "live" ? "on" : ""} onClick={() => setMode("live")}>Record</button>
        <button className={mode === "upload" ? "on" : ""} onClick={() => setMode("upload")}>Upload</button>
      </div>

      {mode === "live" ? (
        <section className="card">
          <div className="row">
            <label className="chk">
              <input type="checkbox" checked={captureSystem} onChange={(e) => setCaptureSystem(e.target.checked)} />
              Capture system audio (any app — Discord, VTT, browser)
            </label>
          </div>
          <div className="row">
            <label>Microphone</label>
            <select value={mic} onChange={(e) => setMic(e.target.value)}>
              {devices.length === 0 && <option value="default">Default microphone</option>}
              {devices.map((d) => <option key={d.id} value={d.id}>{d.name}{d.is_default ? " (default)" : ""}</option>)}
            </select>
          </div>
          <div className="meter"><div className="meter-fill" style={{ width: `${Math.round(level * 100)}%` }} /></div>
          <div className="row space">
            <div className="timer">{fmt(elapsed)}</div>
            <button className={recording ? "danger" : "primary"} onClick={toggleRecord}>
              {recording ? "Stop" : "Start recording"}
            </button>
          </div>
          <p className="muted small">Backend: system audio = <code>{backends?.system_audio ?? "…"}</code>, mic = <code>{backends?.microphone ?? "…"}</code></p>
        </section>
      ) : (
        <section className="card">
          <label>Audio file (wav / mp3 / m4a / flac)</label>
          <input type="file" accept=".wav,.mp3,.m4a,.flac,audio/*" onChange={(e) => setFileName(e.target.files?.[0]?.name ?? null)} />
          {fileName && <p className="muted small">Selected: {fileName} — will import into the campaign vault (CIP-151).</p>}
        </section>
      )}

      <section className="card">
        <h2>Session details</h2>
        <div className="grid2">
          <div>
            <label>Title</label>
            <input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Session title (optional)" />
          </div>
          <div>
            <label>Session number</label>
            <input type="number" step="0.1" value={num} onChange={(e) => setNum(parseFloat(e.target.value))} />
          </div>
          <div>
            <label>Recording date &amp; time</label>
            <input type="datetime-local" value={recordedAt} onChange={(e) => setRecordedAt(e.target.value)} />
          </div>
        </div>
        {err && <p className="error">{err}</p>}
        {msg && <p className="ok">{msg}</p>}
        <button className="primary" onClick={save}>Save session</button>
        <p className="muted small">
          Whole numbers = main sessions (7.0); decimals slot inserts/late uploads (7.5). Ordered ascending regardless of capture order.
        </p>
      </section>
    </div>
  );
}

function fmt(s: number) {
  const m = Math.floor(s / 60).toString().padStart(2, "0");
  const ss = (s % 60).toString().padStart(2, "0");
  return `${m}:${ss}`;
}
function localISO(d: Date) {
  const p = (n: number) => n.toString().padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}
function toUTC(local: string) {
  return new Date(local).toISOString();
}
