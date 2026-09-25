// lce-cleanup — retention purge for the LCE Article Studio.
//
// Deletes expired trashed articles, their images, expired rejected images, and
// stale done/failed image_requests, plus the corresponding objects in the
// project-assets bucket. Invoked daily by pg_cron job `lce-daily-cleanup`.
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

const BUCKET = "project-assets";
const GRACE_DEFAULT = 30;
const GRACE_MIN = 1;    // 0 or less would set the cutoff at or after "now"
const GRACE_MAX = 365;

Deno.serve(async (req: Request) => {
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

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

  const cutoff = new Date(Date.now() - graceDays * 86400000).toISOString();
  const log: any[] = [];
  const summary = { articles: 0, images: 0, requests: 0, storage_removed: 0, grace_days: graceDays };

  // 1) expired trashed articles
  const { data: arts } = await sb.from("articles").select("id,title,user_id").eq("status", "trashed").lt("trashed_at", cutoff);
  const artIds = (arts ?? []).map((a: any) => a.id);

  // images to remove: those belonging to expiring articles + expired rejected images anywhere
  const paths: string[] = [];
  const imgIds: string[] = [];
  if (artIds.length) {
    const { data: imgs } = await sb.from("image_assets").select("id,storage_path,user_id").in("article_id", artIds);
    for (const im of imgs ?? []) { imgIds.push(im.id); if (im.storage_path) paths.push(im.storage_path); log.push({ user_id: im.user_id, entity_type: "image", entity_id: im.id, storage_path: im.storage_path, reason: "auto_purge", grace_days: graceDays }); }
  }
  const { data: rej } = await sb.from("image_assets").select("id,storage_path,user_id").eq("status", "rejected").lt("updated_at", cutoff);
  for (const im of rej ?? []) { imgIds.push(im.id); if (im.storage_path) paths.push(im.storage_path); log.push({ user_id: im.user_id, entity_type: "image", entity_id: im.id, storage_path: im.storage_path, reason: "auto_purge", grace_days: graceDays }); }

  if (paths.length) { const { error } = await sb.storage.from(BUCKET).remove(paths); if (!error) summary.storage_removed = paths.length; }
  if (imgIds.length) { await sb.from("image_assets").delete().in("id", imgIds); summary.images = imgIds.length; }
  for (const a of arts ?? []) log.push({ user_id: a.user_id, entity_type: "article", entity_id: a.id, title: a.title, reason: "auto_purge", grace_days: graceDays });
  if (artIds.length) { await sb.from("articles").delete().in("id", artIds); summary.articles = artIds.length; }

  // 2) stale done/failed image_requests (>7d, independent of graceDays)
  const reqCut = new Date(Date.now() - 7 * 86400000).toISOString();
  const { data: reqs } = await sb.from("image_requests").select("id").in("status", ["done", "failed"]).lt("updated_at", reqCut);
  const reqIds = (reqs ?? []).map((r: any) => r.id);
  if (reqIds.length) { await sb.from("image_requests").delete().in("id", reqIds); summary.requests = reqIds.length; }

  if (log.length) await sb.from("lce_deletion_log").insert(log);
  return new Response(JSON.stringify({ ok: true, ...summary, at: new Date().toISOString() }), { headers: { "content-type": "application/json" } });
});
