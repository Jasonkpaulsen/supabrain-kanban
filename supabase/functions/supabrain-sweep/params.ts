// SB-495: parameter resolution and truncation reporting for supabrain-sweep.
//
// 1. Parameters. Up to v3, `params` was one flat object handed to every
//    operation in the call, and operations disagreed about what a name meant:
//    `staleDays` was "backlog untouched" (default 45) to
//    backlog_grooming_report and "in-progress untouched" (default 3) to
//    stale_wip. The architect's review of SB-482 demonstrated it live:
//
//        {"operations":["backlog_grooming_report","stale_wip"],"params":{"staleDays":2}}
//        -> the grooming report listed 195 items instead of its default 54
//
//    Now every operation declares its parameters and what each one MEANS. A
//    flat name is accepted only when every operation in the call that reads
//    it gives it the same meaning; otherwise the request is refused and the
//    caller is shown the per-operation form, {"stale_wip": {"staleDays": 2}}.
//    Refusing is louder than guessing, which is the point.
//
//    Also refused, rather than quietly ignored: a parameter no operation in
//    the call reads (a typo like "staleday" used to fall back to the default
//    without a word), a non-numeric value (same), and a per-operation block
//    for an operation that is not in the call. Out-of-range numbers are still
//    clamped, but the effective values are echoed in the response, so the
//    clamp is visible.
//
// 2. Truncation. Reads were capped (500 rows, and 5000 on the work-item fetch
//    behind agent_load / agents_idle_with_queue) and `count` was the length of
//    the returned array, so a cut-off report read as a complete one. The API
//    also applies its own row cap, which can cut a result short below the
//    requested limit. Each read now asks the database for the true total, and
//    `truncated()` compares the two.
//
// Kept in its own module, with no Deno or Supabase imports, so the test
// imports the code that ships, not a copy.

export type ParamSpec = {
  /** What the number means. Two operations share a flat name only if this matches. */
  meaning: string;
  def: number;
  lo: number;
  hi: number;
};

/**
 * Every parameter every operation reads. An operation absent from this table
 * reads none. index.ts asserts at start-up that each key here is a real
 * operation, so the two cannot drift apart silently.
 */
export const PARAM_SPECS: Record<string, Record<string, ParamSpec>> = {
  backlog_grooming_report: {
    staleDays: { meaning: "days a backlog item has gone untouched", def: 45, lo: 1, hi: 365 },
  },
  agents_idle_with_queue: {
    idleDays: { meaning: "days since an agent last ran", def: 7, lo: 1, hi: 90 },
  },
  review_queue_aging: {
    ageHours: { meaning: "hours an item has sat in review", def: 48, lo: 1, hi: 24 * 90 },
  },
  // stale_wip and blocked_items share a meaning on purpose: both ask how long
  // open, non-backlog work has gone untouched, with the same default, and they
  // run together in pm-triage-dispatch. Tuning one for that bundle is meant to
  // tune both.
  stale_wip: {
    staleDays: { meaning: "days open work has gone untouched", def: 3, lo: 1, hi: 365 },
  },
  blocked_items: {
    staleDays: { meaning: "days open work has gone untouched", def: 3, lo: 1, hi: 365 },
  },
};

export type Resolved =
  | { ok: true; perOp: Record<string, Record<string, number>> }
  | { ok: false; error: string; detail: Record<string, unknown> };

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** A finite number, or a string that is one. Anything else is null. */
function toNumber(v: unknown): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : null;
}

function clamp(n: number, s: ParamSpec): number {
  return Math.min(s.hi, Math.max(s.lo, Math.trunc(n)));
}

/**
 * Turn the caller's `params` into the effective values for each operation in
 * the call. `allOps` is every operation name the endpoint knows, so a block
 * addressed to a real operation that is not in this call can be told apart
 * from an unknown flat parameter.
 */
export function resolveParams(
  names: string[],
  raw: unknown,
  allOps: string[],
  specs: Record<string, Record<string, ParamSpec>> = PARAM_SPECS,
): Resolved {
  const inCall = new Set(names);
  const perOp: Record<string, Record<string, number>> = {};
  for (const op of names) {
    perOp[op] = {};
    for (const [k, s] of Object.entries(specs[op] ?? {})) perOp[op][k] = s.def;
  }

  if (raw === undefined || raw === null) return { ok: true, perOp };
  if (!isPlainObject(raw)) {
    return { ok: false, error: "params must be an object", detail: { got: Array.isArray(raw) ? "array" : typeof raw } };
  }

  const known = new Set(allOps);
  const flat: Array<[string, unknown]> = [];
  const scoped: Array<[string, Record<string, unknown>]> = [];

  for (const [key, value] of Object.entries(raw)) {
    if (known.has(key)) {
      if (!inCall.has(key)) {
        return { ok: false, error: `params.${key} addresses an operation that is not in this call`,
                 detail: { operation: key, operations_in_call: names } };
      }
      if (!isPlainObject(value)) {
        return { ok: false, error: `params.${key} must be an object of that operation's parameters`,
                 detail: { operation: key, accepts: Object.keys(specs[key] ?? {}) } };
      }
      scoped.push([key, value]);
    } else {
      flat.push([key, value]);
    }
  }

  // Flat names: every operation in the call that reads the name must agree on
  // what it means, and at least one must read it.
  for (const [key, value] of flat) {
    const readers = names.filter((op) => specs[op]?.[key]);
    if (readers.length === 0) {
      return { ok: false, error: `unknown parameter "${key}" for this call`,
               detail: { parameter: key, accepted: acceptedFlat(names, specs) } };
    }
    const meanings = new Map<string, string[]>();
    for (const op of readers) {
      const m = specs[op][key].meaning;
      meanings.set(m, [...(meanings.get(m) ?? []), op]);
    }
    if (meanings.size > 1) {
      return {
        ok: false,
        error: `"${key}" means different things to different operations in this call; ` +
          `set it per operation, e.g. {"params": {"${readers[0]}": {"${key}": …}}}`,
        detail: { parameter: key, meanings: Object.fromEntries(meanings) },
      };
    }
    const n = toNumber(value);
    if (n === null) {
      return { ok: false, error: `parameter "${key}" must be a number`, detail: { parameter: key, got: value } };
    }
    for (const op of readers) perOp[op][key] = clamp(n, specs[op][key]);
  }

  // Per-operation blocks are applied last, so they override a flat value.
  for (const [op, block] of scoped) {
    for (const [key, value] of Object.entries(block)) {
      const s = specs[op]?.[key];
      if (!s) {
        return { ok: false, error: `operation "${op}" has no parameter "${key}"`,
                 detail: { operation: op, parameter: key, accepts: Object.keys(specs[op] ?? {}) } };
      }
      const n = toNumber(value);
      if (n === null) {
        return { ok: false, error: `params.${op}.${key} must be a number`,
                 detail: { operation: op, parameter: key, got: value } };
      }
      perOp[op][key] = clamp(n, s);
    }
  }

  return { ok: true, perOp };
}

/** Flat names that are safe to use in this call, for the error message. */
function acceptedFlat(names: string[], specs: Record<string, Record<string, ParamSpec>>): string[] {
  const out = new Set<string>();
  for (const op of names) for (const k of Object.keys(specs[op] ?? {})) out.add(k);
  return [...out].sort();
}

/**
 * Whether a read came back short of what matched. `total` is the database's
 * exact count of matching rows. If it is unavailable, fall back to the only
 * signal left: a page exactly as long as the limit may have been cut.
 */
export function truncated(returned: number, total: number | null, limit: number): boolean {
  if (total !== null) return total > returned;
  return returned >= limit;
}
