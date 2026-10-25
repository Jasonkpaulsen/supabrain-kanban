// lce-cleanup — retention purge for the LCE Article Studio.
//
// Deletes expired trashed articles, their images, expired rejected images, and
// stale done/failed image_requests, plus the corresponding objects in the
// project-assets bucket. Invoked daily by pg_cron job `lce-daily-cleanup`.
//
// SB-635 / SB-633 (2026-10-25): the decisions live in cleanup.ts, unit-tested in
// cleanup.test.ts; this file only does the I/O. A row goes only when its file is
// gone, only what was deleted is logged, and saved/library images survive the
// article they came from.
//
// SB-493 (2026-09-21): the expected token used to be a literal in this file,
// and the SAME literal sat in plaintext in cron.job.command for job 1 — so it
// was in the database, and therefore in every backup, readable by anyone who
// could read that table. That is the fourth instance of the class behind
// SB-408, SB-440 and SB-447, and here it guarded a service-role function whose
// whole purpose is deletion.
//
// It has been rotated into Vault. This function no longer holds it: it asks the
// database whether the presented token matches, via
// public.lce_cleanup_token_matches(), which is EXECUTE-granted to service_role
// only and never returns the secret. The cron job builds its headers from
// public.lce_cleanup_headers() instead of carrying a literal. Do not
// reintroduce a literal here.
//
// SB-493 also clamps graceDays. It is caller-supplied and it drives the
// deletion cutoff: the previous code accepted any number, so a negative value
// moved the cutoff into the future and would have purged every trashed article
// and rejected image regardless of age. It is now coerced and bounded.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { runCleanup, type Io, type Row } from "./cleanup.ts";

const BUCKET = "project-assets";
const GRACE_DEFAULT = 30;
const GRACE_MIN = 1;    // 0 or less would set the cutoff at or after "now"
const GRACE_MAX = 365;

const IMAGE_COLS = "id,storage_path,user_id,status,article_id";

Deno.serve(async (req: Request) => {
  const url = Deno.env.get("SUPABASE_URL")!;
  const sb = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // SB-493: validate against the Vault-held token without ever receiving its value.
  {
    const presented = req.headers.get("x-token") ?? "";
    const { data: ok, error } = await sb.rpc("lce_cleanup_token_matches", { p_token: presented });
    if (error || ok !== true) return new Response("forbidden", { status: 403 });
  }

  let graceDays = GRACE_DEFAULT;
  try {
    const b = await req.json();
    const n = typeof b.graceDays === "number" ? b.graceDays
            : typeof b.graceDays === "string" ? Number(b.graceDays) : NaN;
    if (Number.isFinite(n)) graceDays = Math.min(GRACE_MAX, Math.max(GRACE_MIN, Math.trunc(n)));
  } catch (_) { /* empty body ok */ }

  // deno-lint-ignore no-explicit-any
  const rows = (r: { data: any; error: any }): Row[] => { if (r.error) throw new Error(r.error.message); return (r.data ?? []) as Row[]; };
  const ids = (r: { data: Row[] | null; error: { message: string } | null }): string[] => rows(r).map((x) => x.id);

  const io: Io = {
    expiredArticles: async (cutoff) => rows(await sb.from("articles").select("id,title,user_id").eq("status", "trashed").lt("trashed_at", cutoff)),
    articleImages: async (artIds) => rows(await sb.from("image_assets").select(IMAGE_COLS).in("article_id", artIds)),
    expiredRejected: async (cutoff) => rows(await sb.from("image_assets").select(IMAGE_COLS).eq("status", "rejected").lt("updated_at", cutoff)),
    staleRequests: async (cutoff) => rows(await sb.from("image_requests").select("id,user_id").in("status", ["done", "failed"]).lt("updated_at", cutoff)),
    removeFiles: async (paths) => {
      const { data, error } = await sb.storage.from(BUCKET).remove(paths);
      if (error) throw new Error(error.message);
      return (data ?? []).map((o: { name: string }) => o.name);
    },
    fileGone: async (path) => {
      const r = await fetch(`${url}/storage/v1/object/public/${BUCKET}/${path.split("/").map(encodeURIComponent).join("/")}`, { method: "HEAD" });
      return r.status === 400 || r.status === 404;
    },
    deleteImages: async (xs) => ids(await sb.from("image_assets").delete().in("id", xs).select("id")),
    deleteArticles: async (xs) => ids(await sb.from("articles").delete().in("id", xs).select("id")),
    deleteRequests: async (xs) => ids(await sb.from("image_requests").delete().in("id", xs).select("id")),
    insertLog: async (log) => { const { error } = await sb.from("lce_deletion_log").insert(log); if (error) throw new Error(error.message); },
  };

  const summary = await runCleanup(io, { graceDays, now: Date.now() });
  return new Response(JSON.stringify({ ...summary, at: new Date().toISOString() }), {
    status: summary.ok ? 200 : 500,
    headers: { "content-type": "application/json" },
  });
});
