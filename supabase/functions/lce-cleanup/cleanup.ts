// lce-cleanup's decisions, with every read and write injected so they can be unit-tested
// (cleanup.test.ts). index.ts supplies the real Supabase I/O.
//
// SB-635: a row goes only when its file is gone. Storage remove() reports the objects it removed;
// a path it does not report is checked with a public HEAD (400/404 means already gone, anything
// else keeps the row). Every delete returns the ids it removed, and only those are counted and
// logged; an article goes only when none of its removable images is left behind. image_requests
// purges are logged too. Errors are collected and returned, never swallowed.
//
// SB-633: saved and library images are not part of an article's removal set. article_id is
// ON DELETE SET NULL, so deleting the article detaches them and they stay in the library.
// storage_path is not unique, so a file another surviving row still uses is never removed; the
// purged row just lets go of it. Only project-assets objects are handled; other buckets are kept.

export type Row = {
  id: string;
  user_id?: string | null;
  storage_path?: string | null;
  storage_bucket?: string | null;
  status?: string | null;
  article_id?: string | null;
  title?: string | null;
};

export type LogRow = {
  user_id: string | null;
  entity_type: "article" | "image" | "image_request";
  entity_id: string;
  storage_path?: string | null;
  title?: string | null;
  reason: "auto_purge";
  grace_days: number;
};

export interface Io {
  expiredArticles(cutoff: string): Promise<Row[]>;
  articleImages(articleIds: string[]): Promise<Row[]>;
  expiredRejected(cutoff: string): Promise<Row[]>;
  staleRequests(cutoff: string): Promise<Row[]>;
  /** Which of these paths are still used by image_assets rows outside excludeIds. */
  pathsInUse(paths: string[], excludeIds: string[]): Promise<string[]>;
  /** Paths the Storage API reports as removed. Throws on an error response. */
  removeFiles(paths: string[]): Promise<string[]>;
  /** True only when the object is definitely absent (public HEAD answered 400 or 404). */
  fileGone(path: string): Promise<boolean>;
  /** Each delete returns the ids it actually removed. */
  deleteImages(ids: string[]): Promise<string[]>;
  deleteArticles(ids: string[]): Promise<string[]>;
  deleteRequests(ids: string[]): Promise<string[]>;
  insertLog(rows: LogRow[]): Promise<void>;
}

export const LIBRARY_STATUSES = new Set(["saved", "library"]);
export const BUCKET = "project-assets";
export const REQUEST_GRACE_DAYS = 7;
const DAY_MS = 86400000;

export type Summary = {
  ok: boolean;
  grace_days: number;
  articles: number;
  articles_kept: number;
  images: number;
  images_kept: number;
  library_kept: number;
  storage_removed: number;
  already_gone: number;
  shared_files: number;
  files_kept: number;
  requests: number;
  logged: number;
  errors: string[];
};

export async function runCleanup(io: Io, opts: { graceDays: number; now: number }): Promise<Summary> {
  const errors: string[] = [];
  async function step<T>(name: string, f: () => Promise<T>, fallback: T): Promise<T> {
    try { return await f(); } catch (e) { errors.push(`${name}: ${e instanceof Error ? e.message : String(e)}`); return fallback; }
  }
  const cutoff = new Date(opts.now - opts.graceDays * DAY_MS).toISOString();

  // 1. Expired trashed articles and their images. If the image lookup fails, no article is deleted.
  const arts = await step<Row[] | null>("select articles", () => io.expiredArticles(cutoff), null) ?? [];
  let artImages: Row[] = [];
  let artImagesKnown = true;
  if (arts.length) {
    const r = await step<Row[] | null>("select article images", () => io.articleImages(arts.map((a) => a.id)), null);
    if (r === null) artImagesKnown = false; else artImages = r;
  }
  const library = artImages.filter((i) => LIBRARY_STATUSES.has(i.status ?? ""));
  const articleOwned = artImages.filter((i) => !LIBRARY_STATUSES.has(i.status ?? ""));

  // 2. Expired rejected images anywhere (never library ones), merged with the article-owned set.
  const rejected = (await step<Row[]>("select rejected images", () => io.expiredRejected(cutoff), []))
    .filter((i) => !LIBRARY_STATUSES.has(i.status ?? ""));
  const byId = new Map<string, Row>();
  for (const i of [...articleOwned, ...rejected]) byId.set(i.id, i);
  const candidates = [...byId.values()];

  // 3. Files: only project-assets ones, and never one another surviving row still uses. If that
  //    lookup fails, no file is removed (and so no row with a file is deleted).
  const ours = (i: Row) => (i.storage_bucket ?? BUCKET) === BUCKET;
  const paths = [...new Set(candidates.filter(ours).map((i) => i.storage_path).filter((p): p is string => !!p))];
  const inUse = paths.length
    ? await step<string[] | null>("check shared paths", () => io.pathsInUse(paths, candidates.map((i) => i.id)), null)
    : [];
  const shared = new Set(inUse ?? []);
  const toRemove = inUse === null ? [] : paths.filter((p) => !shared.has(p));
  const gone = new Set<string>();
  if (toRemove.length) {
    for (const p of await step<string[]>("remove files", () => io.removeFiles(toRemove), [])) if (toRemove.includes(p)) gone.add(p);
  }
  const storageRemoved = gone.size;
  const unsure = toRemove.filter((p) => !gone.has(p));
  const flags = await Promise.all(unsure.map((p) => io.fileGone(p).catch(() => false)));
  unsure.forEach((p, k) => { if (flags[k]) gone.add(p); });
  const alreadyGone = gone.size - storageRemoved;

  // 4. Delete the image rows whose file is gone, still shared, or absent; trust only returned ids.
  const ready = candidates.filter((i) => !i.storage_path || (ours(i) && (gone.has(i.storage_path) || shared.has(i.storage_path))));
  const imgDeleted = new Set(ready.length ? await step<string[]>("delete images", () => io.deleteImages(ready.map((i) => i.id)), []) : []);
  const deletedImages = ready.filter((i) => imgDeleted.has(i.id));

  // 5. An article goes only when every image it owned is gone.
  const blocked = new Set(articleOwned.filter((i) => !imgDeleted.has(i.id)).map((i) => i.article_id));
  const deletable = artImagesKnown ? arts.filter((a) => !blocked.has(a.id)) : [];
  const artDeleted = new Set(deletable.length ? await step<string[]>("delete articles", () => io.deleteArticles(deletable.map((a) => a.id)), []) : []);
  const deletedArticles = deletable.filter((a) => artDeleted.has(a.id));

  // 6. Stale done/failed image requests, on their own clock.
  const reqCutoff = new Date(opts.now - REQUEST_GRACE_DAYS * DAY_MS).toISOString();
  const reqs = await step<Row[]>("select stale requests", () => io.staleRequests(reqCutoff), []);
  const reqDeleted = new Set(reqs.length ? await step<string[]>("delete requests", () => io.deleteRequests(reqs.map((r) => r.id)), []) : []);
  const deletedRequests = reqs.filter((r) => reqDeleted.has(r.id));

  // 7. Log exactly what was deleted.
  const log: LogRow[] = [
    ...deletedImages.map((i): LogRow => ({ user_id: i.user_id ?? null, entity_type: "image", entity_id: i.id, storage_path: i.storage_path ?? null, reason: "auto_purge", grace_days: opts.graceDays })),
    ...deletedArticles.map((a): LogRow => ({ user_id: a.user_id ?? null, entity_type: "article", entity_id: a.id, title: a.title ?? null, reason: "auto_purge", grace_days: opts.graceDays })),
    ...deletedRequests.map((r): LogRow => ({ user_id: r.user_id ?? null, entity_type: "image_request", entity_id: r.id, reason: "auto_purge", grace_days: REQUEST_GRACE_DAYS })),
  ];
  let logged = 0;
  if (log.length && await step<boolean>("insert log", async () => { await io.insertLog(log); return true; }, false)) logged = log.length;

  return {
    ok: errors.length === 0,
    grace_days: opts.graceDays,
    articles: deletedArticles.length,
    articles_kept: arts.length - deletedArticles.length,
    images: deletedImages.length,
    images_kept: candidates.length - deletedImages.length,
    library_kept: library.length,
    storage_removed: storageRemoved,
    already_gone: alreadyGone,
    shared_files: shared.size,
    files_kept: unsure.length - alreadyGone,
    requests: deletedRequests.length,
    logged,
    errors,
  };
}
