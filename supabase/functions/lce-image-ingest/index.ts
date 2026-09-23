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
// Nothing else about this function's behaviour changed in SB-497. In
// particular the caller-supplied `path` is still interpolated into the storage
// URL exactly as before; that is recorded as SB-506 rather than altered here,
// because changing the accepted path shape at the same time as rotating the
// credential would make a breakage impossible to attribute to one or the other.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

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

  const url = new URL(req.url);
  const path = url.searchParams.get("path");
  if (!path) return new Response("no path", { status: 400 });
  const body = new Uint8Array(await req.arrayBuffer());
  const ct = req.headers.get("content-type") || "image/png";
  const up = await fetch(`${SUPABASE_URL}/storage/v1/object/project-assets/${path}`, {
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
