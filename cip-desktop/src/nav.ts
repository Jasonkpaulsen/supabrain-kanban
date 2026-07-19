// Grouped left-nav model — generated from the taxonomy (CIP-123 / CIP-141).
// Overview · Codex · Views · Sessions · Share. Progressive disclosure per group.

export type NavItem = { id: string; label: string; route: string; badge?: boolean };
export type NavGroup = { id: string; label: string; items: NavItem[] };

export const NAV: NavGroup[] = [
  {
    id: "overview",
    label: "Overview",
    items: [
      { id: "dashboard", label: "Dashboard", route: "/" },
      { id: "review", label: "Review", route: "/review", badge: true },
      { id: "ask", label: "Ask", route: "/ask" },
    ],
  },
  {
    id: "codex",
    label: "Codex",
    items: [
      { id: "all", label: "All Pages", route: "/codex" },
      { id: "pcs", label: "Player Characters", route: "/codex/pcs" },
      { id: "npcs", label: "NPCs", route: "/codex/npcs" },
      { id: "locations", label: "Locations", route: "/codex/locations" },
      { id: "factions", label: "Factions & Orgs", route: "/codex/factions" },
      { id: "items", label: "Items", route: "/codex/items" },
      { id: "quests", label: "Quests", route: "/codex/quests" },
      { id: "threads", label: "Plot Threads", route: "/codex/threads" },
    ],
  },
  {
    id: "views",
    label: "Views",
    items: [
      { id: "timeline", label: "Timeline", route: "/timeline" },
      { id: "map", label: "Map", route: "/map" },
      { id: "relationships", label: "Relationships", route: "/relationships" },
    ],
  },
  {
    id: "sessions",
    label: "Sessions",
    items: [
      { id: "record", label: "Record Session", route: "/record" },
      { id: "list", label: "Sessions", route: "/sessions" },
    ],
  },
  {
    id: "share",
    label: "Share",
    items: [{ id: "portal", label: "Player Portal", route: "/share" }],
  },
];
