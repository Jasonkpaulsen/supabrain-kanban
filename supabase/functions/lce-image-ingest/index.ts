// lce-image-ingest — upload a single object into the project-assets bucket.
//
// Called by the "Lce image request fulfiller" routine on Jason's Mac, which
// generates header images and POSTs each PNG here. Writes with the SERVICE ROLE
// key, so whatever authorises a request is the only control on who can write
// into that bucket.
//
// SB-650 (2026-10-28): authorisation is a one-time upload ticket, not a token.
// The routine asks the database for tickets through the Supabase access it
// already has (public.lce_issue_upload_tickets, called with execute_sql); each
// ticket is bound to one object path, expires after 30 minutes and works once.
// The database stores only its sha256. Nothing long-lived sits in the routine's
// prompt or on the Mac any more -- SB-650 found the old static token written in
// plaintext in that prompt, which is how every earlier instance of this class
// started (SB-408, SB-440, SB-447, SB-493, SB-497).
//
// The SB-497 static token is no longer accepted at all: this function does not
// read x-token. public.lce_image_ingest_token_matches() is left in place but
// has no caller, and its Vault secret was overwritten with fresh random bytes
// by the SB-650 migration, so no copy of any earlier value authenticates.
//
// Order matters, for the probe rule (never send a request where any path is
// valid): the ticket is checked first WITHOUT being used, so an unauthorised
// request is refused (403) before the path is looked at; a valid ticket with a
// bad path is refused (400) and the ticket stays unused; only then is the
// ticket consumed against the exact path it was issued for.
//
// SB-506 (2026-09-23): `path` is validated in path.ts by two independent
// layers, an allowlist policy and an invariant that the parsed URL pathname is
// exactly the bucket prefix plus the path. See path.ts and path.test.ts.
//
// x-upsert is false (SB-650): tickets are issued for fresh paths under a new
// set id, so a legitimate upload never replaces an object, and a stolen ticket
// cannot overwrite an existing one.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { checkPath, uploadTarget } from "./path.ts";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const sb = createClient(SUPABASE_URL, SR);

  // SB-650: a live, unused ticket, checked without using it.
  const ticket = req.headers.get("x-upload-ticket") ?? "";
  {
    const { data: ok, error } = await sb.rpc("lce_upload_ticket_valid", { p_ticket: ticket });
    if (error || ok !== true) return new Response("forbidden", { status: 403 });
  }

  // SB-506: validate before anything is read or sent.
  const url = new URL(req.url);
  const check = checkPath(url.searchParams.get("path"));
  if (!check.ok) return new Response(check.reason, { status: 400 });
  const path = check.path;
  const target = uploadTarget(SUPABASE_URL, path);
  if (!target) return new Response("invalid path", { status: 400 });

  // SB-650: use the ticket, atomically, for exactly the path it was issued for.
  {
    const { data: ok, error } = await sb.rpc("lce_consume_upload_ticket", { p_ticket: ticket, p_path: path });
    if (error || ok !== true) return new Response("forbidden", { status: 403 });
  }

  // SB-650: the stored type is always image/png, whatever the caller sends. The bucket also
  // accepts image/svg+xml, and a public SVG under a .png key would be scriptable content.
  const body = new Uint8Array(await req.arrayBuffer());
  const up = await fetch(target, {
    method: "POST",
    headers: { "Authorization": "Bearer " + SR, "apikey": SR, "Content-Type": "image/png", "x-upsert": "false" },
    body,
  });
  const txt = await up.text();
  return new Response(JSON.stringify({
    ok: up.ok,
    status: up.status,
    resp: txt,
    public: `${SUPABASE_URL}/storage/v1/object/public/project-assets/${path}`,
  }), { status: up.ok ? 200 : 502, headers: { "content-type": "application/json" } });
});
