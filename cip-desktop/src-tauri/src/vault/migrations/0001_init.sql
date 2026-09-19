-- CIP campaign vault — migration 0001 (one SQLite vault per campaign).
-- Realizes: ADR-CIP TEXT-UUID PKs (CIP-154), campaigns single-row anchor (CIP-158),
-- session schema with decimal numbering + editable recorded_at + ordering (CIP-149).

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- Single-row, self-describing anchor for this vault. Every entity FKs to campaigns.id.
CREATE TABLE IF NOT EXISTS campaigns (
    id          TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    name        TEXT NOT NULL,
    game_system TEXT,
    settings    TEXT,                                   -- JSON blob
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    -- single-row invariant: only one campaign row per vault
    singleton   INTEGER NOT NULL DEFAULT 1 CHECK (singleton = 1),
    UNIQUE (singleton)
);

-- Sessions: decimal session_number (7.0 main, 7.5 insert), editable recorded_at, source, status.
CREATE TABLE IF NOT EXISTS sessions (
    id               TEXT PRIMARY KEY DEFAULT (lower(hex(randomblob(16)))),
    campaign_id      TEXT NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    session_number   NUMERIC(4,1) NOT NULL,             -- one decimal place; sort ascending
    title            TEXT,
    source           TEXT NOT NULL CHECK (source IN ('live','upload')),
    recorded_at      TEXT NOT NULL,                     -- editable; default 'now' for live
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    audio_ref        TEXT,                              -- vault-relative path (assets/...)
    duration_seconds INTEGER,
    status           TEXT NOT NULL DEFAULT 'imported'
                       CHECK (status IN ('recording','imported','processing','ready','review')),
    meta             TEXT,                              -- JSON blob
    UNIQUE (campaign_id, session_number)
);

CREATE INDEX IF NOT EXISTS idx_sessions_order  ON sessions (campaign_id, session_number ASC);
CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions (campaign_id, status);

-- Schema version bookkeeping.
CREATE TABLE IF NOT EXISTS schema_migrations (
    version    INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
INSERT OR IGNORE INTO schema_migrations (version) VALUES (1);
