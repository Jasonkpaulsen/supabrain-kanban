import { useState } from "react";
import { NAV } from "./nav";
import CampaignGate from "./views/CampaignGate";
import Dashboard from "./views/Dashboard";
import RecordSession from "./views/RecordSession";
import Sessions from "./views/Sessions";
import Placeholder from "./views/Placeholder";

const CAMPAIGN_KEY = "cip.campaign";
type Campaign = { id: string; name: string };

function loadCampaign(): Campaign | null {
  try {
    const raw = localStorage.getItem(CAMPAIGN_KEY);
    return raw ? (JSON.parse(raw) as Campaign) : null;
  } catch {
    return null;
  }
}

export default function App() {
  const [campaign, setCampaign] = useState<Campaign | null>(loadCampaign);
  const [active, setActive] = useState("dashboard");
  // Bump to force session-backed views to re-read the vault after a save.
  const [rev, setRev] = useState(0);

  if (!campaign) {
    return (
      <CampaignGate
        onReady={(id, name) => {
          const c = { id, name };
          localStorage.setItem(CAMPAIGN_KEY, JSON.stringify(c));
          setCampaign(c);
        }}
      />
    );
  }

  const label = NAV.flatMap((g) => g.items).find((it) => it.id === active)?.label ?? "";

  function body() {
    if (!campaign) return null;
    switch (active) {
      case "dashboard":
        return <Dashboard key={rev} campaignId={campaign.id} campaignName={campaign.name} onRecord={() => setActive("record")} />;
      case "record":
        return <RecordSession campaignId={campaign.id} onSaved={() => { setRev((r) => r + 1); setActive("list"); }} />;
      case "list":
        return <Sessions key={rev} campaignId={campaign.id} onRecord={() => setActive("record")} />;
      default:
        return <Placeholder title={label} />;
    }
  }

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
              </button>
            ))}
          </div>
        ))}
        <button className="nav-switch" onClick={() => { localStorage.removeItem(CAMPAIGN_KEY); setCampaign(null); }}>
          Switch campaign
        </button>
      </nav>
      <main className="content">{body()}</main>
    </div>
  );
}
