import { useState } from "react";
import { api, inTauri } from "../api";

// First-run: create a campaign vault (one vault per campaign).
export default function CampaignGate({ onReady }: { onReady: (id: string, name: string) => void }) {
  const [name, setName] = useState("");
  const [system, setSystem] = useState("D&D 5e");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function create() {
    if (!name.trim()) return;
    setBusy(true);
    setErr(null);
    try {
      const id = crypto.randomUUID();
      if (inTauri()) await api.createCampaign(id, name.trim(), system || null);
      onReady(id, name.trim());
    } catch (e) {
      setErr(String(e));
      setBusy(false);
    }
  }

  return (
    <div className="gate">
      <div className="gate-card">
        <div className="brand-lg">Campaign Intelligence Platform</div>
        <p className="muted">Create a campaign. Each campaign is its own local vault — fully offline.</p>
        <label>Campaign name</label>
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Curse of Strahd" autoFocus />
        <label>Game system</label>
        <input value={system} onChange={(e) => setSystem(e.target.value)} placeholder="D&D 5e" />
        {err && <p className="error">{err}</p>}
        <button className="primary" disabled={busy || !name.trim()} onClick={create}>
          {busy ? "Creating…" : "Create campaign"}
        </button>
        {!inTauri() && <p className="muted small">Browser preview — vault write is skipped outside the desktop app.</p>}
      </div>
    </div>
  );
}
