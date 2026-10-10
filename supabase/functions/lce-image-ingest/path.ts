// SB-506: validation for the caller-supplied `path` in lce-image-ingest.
//
// v2 and earlier interpolated `path` straight into the storage URL:
//
//     `${SUPABASE_URL}/storage/v1/object/project-assets/${path}`
//
// WHATWG URL parsing, which fetch uses, normalises "." and ".." segments, so
// the bucket prefix was not a boundary: "../avatars/x.png" resolved to
// /storage/v1/object/avatars/x.png. The request carries the SERVICE ROLE key
// with x-upsert:true, so a successful write bypasses RLS and overwrites.
//
// Two layers, deliberately independent:
//
//   checkPath    -- the POLICY. An allowlist, not a blocklist: every segment
//                   must be [A-Za-z0-9._-]+, and "." / ".." / empty segments
//                   are refused. All 13 objects in the bucket at the time of
//                   writing fit it (shape: lce-images/<uuid>/candidate-N.png),
//                   so no legitimate caller is affected.
//
//   uploadTarget -- the INVARIANT. After building the URL, its parsed pathname
//                   must equal the prefix plus the path exactly. If URL
//                   parsing rewrote anything at all, refuse. This holds even
//                   if someone later loosens the allowlist, which is why it is
//                   a separate check rather than folded into checkPath.
//
// Kept in its own module so the test imports the code that ships, not a copy.

export const PREFIX = "/storage/v1/object/project-assets/";
export const MAX_PATH_LEN = 512;
const SEGMENT = /^[A-Za-z0-9._-]+$/;

export type PathCheck = { ok: true; path: string } | { ok: false; reason: string };

export function checkPath(raw: string | null): PathCheck {
  // "no path" is the exact v2 response and SB-497's verification probes rely
  // on it as the "authenticated, stopped before upload" signal. Keep it.
  if (raw === null || raw === "") return { ok: false, reason: "no path" };
  if (raw.length > MAX_PATH_LEN) return { ok: false, reason: "invalid path: too long" };
  for (const seg of raw.split("/")) {
    // Empty covers a leading "/", a trailing "/" and "//".
    if (seg === "") return { ok: false, reason: "invalid path: empty segment" };
    if (seg === "." || seg === "..") return { ok: false, reason: "invalid path: dot segment" };
    if (!SEGMENT.test(seg)) return { ok: false, reason: "invalid path: disallowed character" };
  }
  return { ok: true, path: raw };
}

export function uploadTarget(supabaseUrl: string, path: string): string | null {
  const target = `${supabaseUrl}/storage/v1/object/project-assets/${path}`;
  let parsed: URL;
  try {
    parsed = new URL(target);
  } catch {
    return null;
  }
  // Exact equality, not startsWith: a rewrite that happens to stay inside the
  // bucket is still a rewrite, and means the stored key is not what the caller
  // asked for. Query strings and fragments also fail this, because they move
  // characters out of the pathname.
  if (parsed.pathname !== PREFIX + path || parsed.search !== "" || parsed.hash !== "") return null;
  return target;
}
