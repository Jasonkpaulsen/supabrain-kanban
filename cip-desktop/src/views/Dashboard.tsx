import { useEffect, useState } from "react";
import { api, inTauri, type CaptureBackends, type Session } from "../api";

// Campaign home — capture readiness + recent sessions, the two things a GM cares about first.
export default function Dashboard({
  campaignId,
  campaignName,
  onRecord,
}: {
  campaignId: string;
  campaignName: string;
  onRecord: () => void;
}) {
  const [backends, setBackends] = useState<CaptureBackends | null>(null);
  const [liveOk, setLiveOk] = useState<boolean | null>(null);
  const [sessions, setSessions] = useState<Session[]>([]);

  useEffect(() => {
    if (!inTauri()) return;
    api.captureBackends().then(setBackends).catch(() => {});
    api.liveCaptureAvailable().then(setLiveOk).catch(() => setLiveOk(false));
    api.listSessions(campaignId).then(setSessions).catch(() => {});
  }, [campaignId]);

  const recent = sessions.slice(-5).reverse();

  return (
    <div>
      <h1>{campaignName}</h1>
      <p className="muted">Local-first · one vault per campaign · fully offline.</p>

      <div className="grid2">
        <section className="card">
          <h2>Capture readiness</h2>
          <div className="stat">
            <span className={"dot " + (liveOk ? "ok" : "warn")} />
            {liveOk === null ? "Probing…" : liveOk ? "System-audio capture ready" : "Native capture not available yet (CIP-150)"}
          </div>
          <p className="muted small">
            System audio: <code>{backends?.system_audio ?? "…"}</code> · Mic: <code>{backends?.microphone ?? "…"}</code>
          </p>
          <button className="primary" onClick={onRecord}>Record a session</button>
        </section>

        <section className="card">
          <h2>Vault</h2>
          <div className="bignum">{sessions.length}</div>
          <p className="muted small">session{sessions.length === 1 ? "" : "s"} captured</p>
        </section>
      </div>

      <section className="card">
        <h2>Recent sessions</h2>
        {recent.length === 0 ? (
          <p className="muted">Nothing recorded yet.</p>
        ) : (
          <ul className="feed">
            {recent.map((s) => (
              <li key={s.id}>
                <span className="num">{s.session_number.toFixed(1)}</span>
                <span>{s.title || "Untitled"}</span>
                <span className="tag">{s.source}</span>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
