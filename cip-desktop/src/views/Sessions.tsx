import { useEffect, useState } from "react";
import { api, inTauri, type Session } from "../api";

// Session catalogue (CIP-149) — ordered ascending, whole numbers = main sessions, decimals = inserts.
export default function Sessions({ campaignId, onRecord }: { campaignId: string; onRecord: () => void }) {
  const [sessions, setSessions] = useState<Session[]>([]);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!inTauri()) return;
    api.listSessions(campaignId).then(setSessions).catch((e) => setErr(String(e)));
  }, [campaignId]);

  return (
    <div>
      <div className="row space">
        <h1>Sessions</h1>
        <button className="primary" onClick={onRecord}>+ Record session</button>
      </div>
      {err && <p className="error">{err}</p>}
      {sessions.length === 0 ? (
        <section className="card empty">
          <p className="muted">No sessions yet. Record or upload your first session to start building the vault.</p>
          <button className="primary" onClick={onRecord}>Record a session</button>
        </section>
      ) : (
        <section className="card">
          <table className="tbl">
            <thead>
              <tr><th>#</th><th>Title</th><th>Source</th><th>Recorded</th><th>Status</th></tr>
            </thead>
            <tbody>
              {sessions.map((s) => (
                <tr key={s.id}>
                  <td className="num">{s.session_number.toFixed(1)}</td>
                  <td>{s.title || <span className="muted">Untitled</span>}</td>
                  <td><span className="tag">{s.source}</span></td>
                  <td className="muted">{fmtDate(s.recorded_at)}</td>
                  <td><span className={"tag " + s.status}>{s.status}</span></td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}
    </div>
  );
}

function fmtDate(iso: string) {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}
