// lce-image-ingest — upload a single object into the project-assets bucket.
//
// Invoked off-platform (no cron job and no database function calls it). Writes
// with the SERVICE ROLE key and x-upsert:true at a caller-chosen path, so the
// token is the only control on who can write or overwrite objects in that
// bucket.
//
// SB-497 (2026-09-23): the expected token used to be a literal in this file.
// That is the fifth instance of the class behind SB-408, SB-440, SB-447 and
// SB-493, and the last one open. It has been rotated into Vault. This function
// no longer holds it: it asks the database whether the presented token matches,
// via public.lce_image_ingest_token_matches(), which is EXECUTE-granted to
// service_role only and never returns the secret. Do not reintroduce a literal
// here.
//
// Unlike lce-cleanup there is deliberately no lce_image_ingest_headers()
// helper: nothing inside the database calls this endpoint, so a jsonb helper
// that returns the plaintext secret would have no caller to justify it. The
// SB-497 migration asserts that it does not exist.
//
// SB-497 deliberately left the caller-supplied `path` alone, so that a
// breakage could be attributed to the rotation or to path handling, not both.
//
// SB-506 (2026-09-23): `path` used to be interpolated straight into the storage
// URL, and URL parsing normalises ".." -- so "../avatars/x.png" escaped the
// bucket, writing with the service-role key. It is now validated in path.ts by
// two independent layers: an allowlist policy, and an invariant that the parsed
// URL pathname is exactly the bucket prefix plus the path. See path.ts for why
// they are separate, and path.test.ts for the proof.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { checkPath, uploadTarget } from "./path.ts";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const sb = createClient(SUPABASE_URL, SR);

  // SB-497: validate against the Vault-held token without ever receiving its value.
  {
    const presented = req.headers.get("x-token") ?? "";
    const { data: ok, error } = await sb.rpc("lce_image_ingest_token_matches", { p_token: presented });
    if (error || ok !== true) return new Response("forbidden", { status: 403 });
  }

  // SB-506: validate before anything is read or sent.
  const url = new URL(req.url);
  const check = checkPath(url.searchParams.get("path"));
  if (!check.ok) return new Response(check.reason, { status: 400 });
  const path = check.path;
  const target = uploadTarget(SUPABASE_URL, path);
  if (!target) return new Response("invalid path", { status: 400 });
  const body = new Uint8Array(await req.arrayBuffer());
  const ct = req.headers.get("content-type") || "image/png";
  const up = await fetch(target, {
    method: "POST",
    headers: { "Authorization": "Bearer " + SR, "apikey": SR, "Content-Type": ct, "x-upsert": "true" },
    body,
  });
  const txt = await up.text();
  return new Response(JSON.stringify({
    status: up.status,
    resp: txt,
    public: `${SUPABASE_URL}/storage/v1/object/public/project-assets/${path}`,
  }), { headers: { "content-type": "application/json" } });
});
