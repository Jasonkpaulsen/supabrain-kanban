// SB-635 / SB-633: lce-cleanup's decisions, against a fake backend.
//
// Run:  node --experimental-strip-types --test supabase/functions/lce-cleanup/cleanup.test.ts

import { test } from "node:test";
import assert from "node:assert/strict";
import { runCleanup, type Io, type LogRow, type Row } from "./cleanup.ts";

const NOW = Date.parse("2026-10-25T07:00:00Z");
const OLD = "2026-08-01T00:00:00Z";

type World = {
  articles: Row[];
  images: Row[];
  requests: Row[];
  files: Set<string>;
  hidden: Set<string>;            // files the remove call will not take (reported as nothing removed)
  removeError?: string;
  deleteImagesError?: string;
  deleteArticlesShort?: boolean;  // the delete returns fewer ids than asked
  logError?: string;
  head?: (path: string) => boolean | "throw";
  extraRemoved?: string;          // remove() also reports a path that was not asked for
  inUseError?: string;
  shortRequests?: boolean;        // the request delete returns fewer ids than asked
};

function world(over: Partial<World> = {}): World {
  return {
    articles: [{ id: "a1", title: "T1", user_id: "u" }, { id: "a2", title: "T2", user_id: "u" }],
    images: [
      { id: "c1", storage_path: "lce-images/a1/candidate-1.png", status: "candidate", article_id: "a1", user_id: "u" },
      { id: "h1", storage_path: "lce-images/a1/candidate-2.png", status: "accepted", article_id: "a1", user_id: "u" },
      { id: "s1", storage_path: "lce-images/a1/candidate-3.png", status: "saved", article_id: "a1", user_id: "u" },
      { id: "l1", storage_path: "lce-images/a1/lib.png", status: "library", article_id: "a1", user_id: "u" },
      { id: "c2", storage_path: "lce-images/a2/candidate-1.png", status: "candidate", article_id: "a2", user_id: "u" },
      { id: "nf", storage_path: null, status: "candidate", article_id: "a2", user_id: "u" },
      { id: "r1", storage_path: "lce-images/x/rejected.png", status: "rejected", article_id: null, user_id: "u" },
    ],
    requests: [{ id: "q1", user_id: "u" }],
    files: new Set(["lce-images/a1/candidate-1.png", "lce-images/a1/candidate-2.png", "lce-images/a1/candidate-3.png",
                    "lce-images/a1/lib.png", "lce-images/a2/candidate-1.png", "lce-images/x/rejected.png"]),
    hidden: new Set(),
    ...over,
  };
}

function fake(w: World) {
  const calls = { removed: [] as string[][], heads: [] as string[], deleted: { images: [] as string[][], articles: [] as string[][], requests: [] as string[][] }, log: [] as LogRow[] };
  const io: Io = {
    expiredArticles: async () => w.articles,
    articleImages: async (ids) => w.images.filter((i) => ids.includes(i.article_id ?? "")),
    expiredRejected: async () => w.images.filter((i) => i.status === "rejected"),
    staleRequests: async () => w.requests,
    pathsInUse: async (paths, exclude) => {
      if (w.inUseError) throw new Error(w.inUseError);
      return [...new Set(w.images.filter((i) => !exclude.includes(i.id) && (i.storage_bucket ?? "project-assets") === "project-assets"
        && paths.includes(i.storage_path ?? "")).map((i) => i.storage_path as string))];
    },
    removeFiles: async (paths) => {
      calls.removed.push(paths);
      if (w.removeError) throw new Error(w.removeError);
      const out = paths.filter((p) => w.files.has(p) && !w.hidden.has(p));
      out.forEach((p) => w.files.delete(p));
      return w.extraRemoved ? [...out, w.extraRemoved] : out;
    },
    fileGone: async (p) => {
      calls.heads.push(p);
      const h = w.head ? w.head(p) : !w.files.has(p);
      if (h === "throw") throw new Error("network");
      return h;
    },
    deleteImages: async (ids) => {
      calls.deleted.images.push(ids);
      if (w.deleteImagesError) throw new Error(w.deleteImagesError);
      w.images = w.images.filter((i) => !ids.includes(i.id));
      return ids;
    },
    deleteArticles: async (ids) => {
      calls.deleted.articles.push(ids);
      const done = w.deleteArticlesShort ? ids.slice(1) : ids;
      w.articles = w.articles.filter((a) => !done.includes(a.id));
      // ON DELETE SET NULL
      w.images.forEach((i) => { if (done.includes(i.article_id ?? "")) i.article_id = null; });
      return done;
    },
    deleteRequests: async (ids) => {
      calls.deleted.requests.push(ids);
      const done = w.shortRequests ? [] : ids;
      w.requests = w.requests.filter((r) => !done.includes(r.id));
      return done;
    },
    insertLog: async (rows) => { if (w.logError) throw new Error(w.logError); calls.log.push(...rows); },
  };
  return { io, calls };
}

const ids = (rows: LogRow[], type: string) => rows.filter((r) => r.entity_type === type).map((r) => r.entity_id).sort();

test("TC-SB633-01: saved and library images survive; their article is still deleted", async () => {
  const w = world();
  const { io, calls } = fake(w);
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.equal(s.ok, true, s.errors.join("; "));
  assert.ok(!calls.removed.flat().includes("lce-images/a1/candidate-3.png"));
  assert.ok(!calls.removed.flat().includes("lce-images/a1/lib.png"));
  assert.ok(!calls.deleted.images.flat().includes("s1") && !calls.deleted.images.flat().includes("l1"));
  assert.deepEqual(calls.deleted.articles, [["a1", "a2"]]);
  assert.equal(s.library_kept, 2);
  // detached by the FK, still present
  assert.deepEqual(w.images.filter((i) => i.id === "s1" || i.id === "l1").map((i) => i.article_id), [null, null]);
  assert.deepEqual(ids(calls.log, "image"), ["c1", "c2", "h1", "nf", "r1"]);
});

test("TC-SB635-01: a storage failure keeps the rows and the articles, logs nothing, reports the error", async () => {
  const w = world({ removeError: "storage down", head: () => false });
  const { io, calls } = fake(w);
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.equal(s.ok, false);
  assert.match(s.errors.join(";"), /remove files: storage down/);
  // only the file-less row may go; nothing else
  assert.deepEqual(calls.deleted.images, [["nf"]]);
  assert.deepEqual(calls.deleted.articles, []);
  assert.deepEqual(ids(calls.log, "image"), ["nf"]);
  assert.deepEqual(ids(calls.log, "article"), []);
  assert.equal(s.articles_kept, 2);
});

test("TC-SB635-02: a file already gone counts as removed; an unknown answer keeps the row", async () => {
  // c1's file vanished before this run (an earlier failed row delete); rejected.png is hidden from remove.
  const w = world();
  w.files.delete("lce-images/a1/candidate-1.png");
  w.hidden.add("lce-images/x/rejected.png");
  w.head = (p) => (p.endsWith("rejected.png") ? "throw" : !w.files.has(p));
  const { io, calls } = fake(w);
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.equal(s.already_gone, 1);
  assert.ok(calls.heads.includes("lce-images/a1/candidate-1.png"));
  assert.ok(calls.deleted.images.flat().includes("c1"));
  assert.ok(!calls.deleted.images.flat().includes("r1"), "a network error must not count as gone");
  assert.equal(s.images_kept, 1);
  assert.deepEqual(ids(calls.log, "article"), ["a1", "a2"]);
});

test("TC-SB635-02: a 500 on the existence check keeps the row and blocks its article", async () => {
  const w = world();
  w.hidden.add("lce-images/a2/candidate-1.png");
  w.head = () => false;   // e.g. HEAD answered 500
  const { io, calls } = fake(w);
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.ok(!calls.deleted.images.flat().includes("c2"));
  assert.deepEqual(calls.deleted.articles, [["a1"]]);
  assert.equal(s.articles_kept, 1);
  assert.deepEqual(ids(calls.log, "article"), ["a1"]);
});

test("TC-SB635-03: a failed image delete keeps every article and logs no images", async () => {
  const w = world({ deleteImagesError: "row delete down" });
  const { io, calls } = fake(w);
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.equal(s.ok, false);
  assert.deepEqual(calls.deleted.articles, []);
  assert.deepEqual(ids(calls.log, "image"), []);
  assert.deepEqual(ids(calls.log, "article"), []);
  assert.equal(s.images, 0);
});

test("TC-SB635-03: only article ids the delete returned are logged", async () => {
  const w = world({ deleteArticlesShort: true });
  const { io, calls } = fake(w);
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.deepEqual(ids(calls.log, "article"), ["a2"]);
  assert.equal(s.articles, 1);
});

test("TC-SB635-03: image_requests purges are logged; a failed log insert is reported, not counted", async () => {
  const w = world();
  const { io, calls } = fake(w);
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.deepEqual(ids(calls.log, "image_request"), ["q1"]);
  assert.equal(calls.log.find((r) => r.entity_type === "image_request")?.grace_days, 7);
  assert.equal(s.logged, calls.log.length);

  const w2 = world({ logError: "log down" });
  const f2 = fake(w2);
  const s2 = await runCleanup(f2.io, { graceDays: 30, now: NOW });
  assert.equal(s2.ok, false);
  assert.equal(s2.logged, 0);
  assert.match(s2.errors.join(";"), /insert log: log down/);
});

// Verifier, 2026-10-25: storage_path is not unique. A file a surviving row still uses stays.
test("TC-SB633-01: a file shared with a surviving library row is not removed", async () => {
  const w = world();
  w.images.push({ id: "lib2", storage_path: "lce-images/a2/candidate-1.png", status: "library", article_id: null, user_id: "u" });
  const { io, calls } = fake(w);
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.ok(!calls.removed.flat().includes("lce-images/a2/candidate-1.png"), "shared file must stay");
  assert.ok(w.files.has("lce-images/a2/candidate-1.png"));
  assert.ok(calls.deleted.images.flat().includes("c2"), "the purged row lets go of the shared file");
  assert.equal(s.shared_files, 1);
  assert.deepEqual(ids(calls.log, "article"), ["a1", "a2"]);
});

test("a failed shared-path lookup removes no file and deletes only file-less rows", async () => {
  const w = world({ inUseError: "lookup down" });
  const { io, calls } = fake(w);
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.equal(s.ok, false);
  assert.deepEqual(calls.removed, []);
  assert.deepEqual(calls.deleted.images, [["nf"]]);
  assert.deepEqual(calls.deleted.articles, []);
});

test("rows outside project-assets are kept and block their article", async () => {
  const w = world();
  w.images.find((i) => i.id === "c2")!.storage_bucket = "other-bucket";
  const { io, calls } = fake(w);
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.ok(!calls.removed.flat().includes("lce-images/a2/candidate-1.png"));
  assert.ok(!calls.deleted.images.flat().includes("c2"));
  assert.deepEqual(calls.deleted.articles, [["a1"]]);
  assert.equal(s.articles_kept, 1);
});

test("counts: storage_removed is what remove() reported, ignoring paths not asked for; files_kept counts the unsure", async () => {
  const w = world({ extraRemoved: "lce-images/unrelated.png" });
  w.hidden.add("lce-images/x/rejected.png");
  w.head = () => false;
  const { io } = fake(w);
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.equal(s.storage_removed, 3);   // c1, h1 and c2 files; rejected is hidden; the unrelated path is ignored
  assert.equal(s.files_kept, 1);
  assert.equal(s.images_kept, 1);
});

test("only request ids the delete returned are logged", async () => {
  const w = world({ shortRequests: true });
  const { io, calls } = fake(w);
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.equal(s.requests, 0);
  assert.deepEqual(ids(calls.log, "image_request"), []);
});

test("a failed image lookup deletes no article", async () => {
  const w = world();
  const { io, calls } = fake(w);
  io.articleImages = async () => { throw new Error("lookup down"); };
  const s = await runCleanup(io, { graceDays: 30, now: NOW });
  assert.equal(s.ok, false);
  assert.deepEqual(calls.deleted.articles, []);
  assert.equal(s.articles_kept, 2);
});

test("cutoffs: articles use graceDays, requests use 7 days", async () => {
  const seen: string[] = [];
  const w = world();
  const { io } = fake(w);
  io.expiredArticles = async (c) => { seen.push(`a:${c}`); return []; };
  io.expiredRejected = async (c) => { seen.push(`r:${c}`); return []; };
  io.staleRequests = async (c) => { seen.push(`q:${c}`); return []; };
  await runCleanup(io, { graceDays: 30, now: NOW });
  assert.deepEqual(seen, ["a:2026-09-25T07:00:00.000Z", "r:2026-09-25T07:00:00.000Z", "q:2026-10-18T07:00:00.000Z"]);
  assert.ok(OLD < "2026-09-25");
});

test("index.ts wires every delete to return ids and keeps the SB-493 guards", async () => {
  const { readFileSync } = await import("node:fs");
  const src = readFileSync(new URL("./index.ts", import.meta.url), "utf8");
  for (const t of ["image_assets", "articles", "image_requests"]) {
    assert.match(src, new RegExp(`from\\("${t}"\\)\\.delete\\(\\)\\.in\\("id", xs\\)\\.select\\("id"\\)`), t);
  }
  assert.match(src, /lce_cleanup_token_matches/);
  assert.match(src, /GRACE_MIN = 1/);
  assert.doesNotMatch(src.replace(/\/\/[^\n]*/g, ""), /x-token"\) === "/, "no literal token comparison");
});
