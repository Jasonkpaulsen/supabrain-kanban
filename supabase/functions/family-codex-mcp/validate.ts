// SB-825 / SB-826 / SB-827 — pure input checks and identity-refusal helpers for
// family-codex-mcp v6.
//
// Kept free of Deno globals and npm: imports so it runs under Node's
// --experimental-strip-types in CI (function-tests.yml), exactly like controls.ts.
//
//   SB-825  length/type caps on every writable field, list caps (capRows)
//   SB-826  isReadToolName: the read/write split the DB rate limit uses
//   SB-827  identity-refusal reason codes, the refusal-audit request, a per-isolate guard

// ------------------------------------------------------------------ errors
// A tool-level refusal. index.ts maps it to `isError: true` with "<code>: <message>",
// and guardedCall audits it as denied/<code> (or error/<code> for transport faults).
export class ToolError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

function bad(message: string): never {
  throw new ToolError("bad_request", message);
}

// ------------------------------------------------------------------ SB-825
export const LIMITS = {
  TITLE: 500,              // work_items.title, family_event.title, school_assignment.title
  DESCRIPTION: 20_000,     // work_items.description, school_assignment.description
  COMMENT: 10_000,         // unchanged (already enforced)
  RECORD_SHORT: 500,       // names, types, statuses, locations, contact names, dose, schedule, pharmacy, ...
  RECORD_CONTACT: 1_000,   // activity.contact_info
  RECORD_URL: 2_000,       // health_provider.portal_url
  RECORD_LONG: 10_000,     // free-text notes fields
  DATE: 40,                // date/timestamp strings (format left to Postgres)
  ENUMISH: 32,             // status / priority / type strings
  INSTRUCTION_SOURCE: 500, // medication instruction_source (checked, not stored)
  PURPOSE: 2_000,          // unchanged
  RESULT_SUMMARY: 8_000,   // unchanged
  TAGS_MAX_ITEMS: 50, TAG: 100,
  LABEL_IDS_MAX: 20,       // schema says maxItems 20; v5 never enforced it
  MAX_BODY_BYTES: 262_144, // whole JSON-RPC request
  LIST_CAP: 100,           // == MAX_LIMIT
  AGENT_PAIRS_FETCH: 1_000 // rows fetched from list_family_agents RPC before grouping
} as const;

// Length in Unicode code points (matches Postgres length() and JSON-Schema maxLength).
// With a max: UTF-16 length >= code points, so a string whose UTF-16 length is within
// the max is within it in code points too, and is not walked.
export function textLen(s: string, max?: number): number {
  if (max !== undefined && s.length <= max) return s.length;
  let n = 0;
  for (const _ of s) n++;
  return n;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type FieldSpec =
  | { kind: "text"; max: number }
  | { kind: "date" }
  | { kind: "uuid" }
  | { kind: "bool" }
  | { kind: "tags" }
  | { kind: "enum"; values: readonly string[] };

const S: FieldSpec = { kind: "text", max: LIMITS.RECORD_SHORT };
const L: FieldSpec = { kind: "text", max: LIMITS.RECORD_LONG };
const D: FieldSpec = { kind: "date" };
const U: FieldSpec = { kind: "uuid" };
const B: FieldSpec = { kind: "bool" };

export const RECORD_FIELD_SPECS: Record<string, Record<string, FieldSpec>> = {
  activity:          { name: S, activity_type: S, location: S, cadence: S, contact_name: S, contact_info: { kind: "text", max: LIMITS.RECORD_CONTACT }, season: S, active: B },
  behavioral_log:    { log_date: D, context: L, trigger: L, response: L, what_worked: L, tags: { kind: "tags" } },
  care_plan:         { plan_type: S, goals: L, accommodations: L, provider_id: U, review_date: D, status: S },
  family_event:      { title: { kind: "text", max: LIMITS.TITLE }, event_type: S, starts_at: D, ends_at: D, location: S },
  health_event:      { provider_id: U, event_type: S, event_date: D, summary: L, follow_up: L },
  health_provider:   { name: S, specialty: S, organization: S, phone: S, email: S, portal_url: { kind: "text", max: LIMITS.RECORD_URL }, notes: L },
  medication:        { name: S, dose: S, schedule: S, prescriber_provider_id: U, start_date: D, end_date: D, refill_due: D, pharmacy: S, adherence_notes: L, active: B },
  school_assignment: { child_name: S, class_name: S, teacher: S, title: { kind: "text", max: LIMITS.TITLE }, description: { kind: "text", max: LIMITS.DESCRIPTION }, assigned_date: D, due_date: D, status: S },
};

// The inputSchema enums, now also enforced server-side.
export const WORK_ITEM_STATUS = ["backlog", "todo", "in_progress", "review", "done", "blocked", "on_hold"] as const;
export const WORK_ITEM_PRIORITY = ["critical", "high", "medium", "low"] as const;
export const WORK_ITEM_TYPE = ["task", "bug", "user_story", "chore"] as const;

export const WORK_ITEM_SPECS: Record<string, FieldSpec> = {
  title: { kind: "text", max: LIMITS.TITLE },
  description: { kind: "text", max: LIMITS.DESCRIPTION },
  status: { kind: "enum", values: WORK_ITEM_STATUS },
  priority: { kind: "enum", values: WORK_ITEM_PRIORITY },
  type: { kind: "enum", values: WORK_ITEM_TYPE },
  due_date: { kind: "date" },
};

function checkText(field: string, v: unknown, max: number) {
  if (typeof v !== "string") bad(`${field} must be a string.`);
  if (textLen(v, max) > max) bad(`${field} exceeds ${max} characters.`);
}

// Throws ToolError("bad_request") on the first field that breaks its spec. Messages
// name the field and the cap, never the value. null clears a value and is allowed
// (required-ness is checked by the caller, as in v5). A field with no spec is refused:
// a writable field nobody wrote a cap for is a gap, not a pass.
export function validateFields(label: string, fields: Record<string, unknown>, specs: Record<string, FieldSpec> | undefined): void {
  if (!specs) bad(`No field rules for ${label}.`);
  for (const [k, v] of Object.entries(fields ?? {})) {
    if (v === undefined || v === null) continue;
    const spec = specs[k];
    if (!spec) bad(`${k} is not a writable field for ${label}.`);
    switch (spec.kind) {
      case "text": checkText(k, v, spec.max); break;
      case "date": checkText(k, v, LIMITS.DATE); break;
      case "uuid":
        if (typeof v !== "string" || !UUID_RE.test(v)) bad(`${k} must be a UUID.`);
        break;
      case "bool":
        if (typeof v !== "boolean") bad(`${k} must be a boolean.`);
        break;
      case "tags": {
        const ok = Array.isArray(v) && v.length <= LIMITS.TAGS_MAX_ITEMS &&
          v.every((t) => typeof t === "string" && textLen(t, LIMITS.TAG) <= LIMITS.TAG);
        if (!ok) bad(`tags may hold at most ${LIMITS.TAGS_MAX_ITEMS} items of at most ${LIMITS.TAG} characters.`);
        break;
      }
      case "enum":
        if (typeof v !== "string" || textLen(v, LIMITS.ENUMISH) > LIMITS.ENUMISH || !spec.values.includes(v)) {
          bad(`${k} must be one of: ${spec.values.join(", ")}.`);
        }
        break;
    }
  }
}

export function checkLabelIds(v: unknown): unknown[] {
  if (!Array.isArray(v) || v.length < 1 || v.length > LIMITS.LABEL_IDS_MAX) {
    bad(`label_ids must hold 1 to ${LIMITS.LABEL_IDS_MAX} ids.`);
  }
  return v;
}

// The code slice is the guarantee; a PostgREST limit only bounds the transfer.
export function capRows<T>(rows: T[] | null | undefined, cap: number): { rows: T[]; truncated: boolean } {
  const input = Array.isArray(rows) ? rows : [];
  return { rows: input.slice(0, cap), truncated: input.length > cap };
}

// ------------------------------------------------------------------ SB-826
// Read tools are exactly list_* / get_*; everything else is a write for limit purposes.
// Same rule as external_connection_precheck (migration sb826_precheck_enforce_all_scopes).
const READ_TOOL_RE = /^(list|get)_[a-z_]+$/;
export function isReadToolName(name: string): boolean {
  return typeof name === "string" && READ_TOOL_RE.test(name);
}

// ------------------------------------------------------------------ SB-827
// Closed set of identity-refusal reasons. Must equal k_token || k_identity in
// external_connection_record_auth_refusal (migration sb827_auth_refusal_audit).
// The server-only marker 'auth_refusals_throttled' is deliberately absent.
export const AUTH_REASONS = [
  "token_missing", "token_malformed", "token_bad_signature", "token_expired",
  "token_not_yet_valid", "token_wrong_issuer", "token_wrong_audience",
  "token_invalid", "token_no_subject", "identity_check_error",
  "client_id_missing", "connection_not_found", "connection_principal_mismatch",
  "connection_proposed", "connection_disabled", "connection_revoked", "connection_expired",
] as const;
export type AuthReason = typeof AUTH_REASONS[number];

const MALFORMED = new Set(["ERR_JWS_INVALID", "ERR_JWT_INVALID"]);
const BAD_SIGNATURE = new Set([
  "ERR_JWS_SIGNATURE_VERIFICATION_FAILED", "ERR_JWKS_NO_MATCHING_KEY", "ERR_JWKS_MULTIPLE_MATCHING_KEYS",
  "ERR_JOSE_ALG_NOT_ALLOWED", "ERR_JOSE_NOT_SUPPORTED",
]);
// Our side could not fetch or read the key set: not the caller's fault.
// ERR_JOSE_GENERIC is thrown by jose 5 only from the JWKS fetch (non-200 response,
// unparseable body), never for anything in the caller's token.
const OUR_FAULT = new Set(["ERR_JWKS_TIMEOUT", "ERR_JWKS_INVALID", "ERR_JOSE_GENERIC"]);
// Every jose error code; anything else did not come from verifying the token.
const JOSE_CODE_RE = /^ERR_(JOSE|JWS|JWT|JWE|JWK|JWKS)_[A-Z_]+$/;

// Maps a jose verification failure to a reason by its code (and claim), never by message.
// A throw without a jose code (a plain network failure such as fetch's TypeError, or any
// other runtime fault) is ours, not the caller's: identity_check_error.
export function classifyJoseError(e: unknown): AuthReason {
  if (!e || typeof e !== "object") return "identity_check_error";
  const code = (e as { code?: unknown }).code;
  if (typeof code !== "string" || !JOSE_CODE_RE.test(code)) return "identity_check_error";
  if (MALFORMED.has(code)) return "token_malformed";
  if (BAD_SIGNATURE.has(code)) return "token_bad_signature";
  if (code === "ERR_JWT_EXPIRED") return "token_expired";
  if (OUR_FAULT.has(code)) return "identity_check_error";
  if (code === "ERR_JWT_CLAIM_VALIDATION_FAILED") {
    const claim = (e as { claim?: unknown }).claim;
    if (claim === "aud") return "token_wrong_audience";
    if (claim === "iss") return "token_wrong_issuer";
    if (claim === "nbf") return "token_not_yet_valid";
  }
  return "token_invalid";
}

// The refusal-audit call. Anonymous (apikey only) unless the token has been verified,
// in which case it rides in Authorization so PostgREST derives auth.uid() and the
// client id itself. The body never carries the token, a client id or a connection id.
export function authRefusalRequest(reason: AuthReason, verifiedToken: string | null, traceId: string, apiKey: string)
  : { headers: Record<string, string>; body: { p_reason_code: string; p_trace_id: string | null } } {
  const headers: Record<string, string> = { apikey: apiKey, "Content-Type": "application/json", Accept: "application/json" };
  if (verifiedToken !== null) headers.Authorization = `Bearer ${verifiedToken}`;
  return { headers, body: { p_reason_code: reason, p_trace_id: UUID_RE.test(traceId) ? traceId : null } };
}

// Per-isolate brake in front of the refusal RPC. Not authoritative (the SQL throttle
// is); it only stops one isolate hammering the database during a flood.
// (No constructor parameter properties: Node's strip-types mode cannot run them.)
export class RefusalAuditGuard {
  private stamps: number[] = [];
  private maxPerWindow: number;
  private windowMs: number;
  private now: () => number;
  constructor(maxPerWindow = 60, windowMs = 60_000, now: () => number = () => Date.now()) {
    this.maxPerWindow = maxPerWindow; this.windowMs = windowMs; this.now = now;
  }
  allow(): boolean {
    const t = this.now();
    this.stamps = this.stamps.filter((s) => t - s < this.windowMs);
    if (this.stamps.length >= this.maxPerWindow) return false;
    this.stamps.push(t);
    return true;
  }
}
