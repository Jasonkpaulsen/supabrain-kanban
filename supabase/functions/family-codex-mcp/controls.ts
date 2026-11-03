// SB-600 — the SB-412 connection controls, applied around every tools/call.
//
// Before a tool runs, external_connection_precheck decides whether it may (connection
// status, expiry, rate limit). After it runs, external_connection_record writes one
// sanitized audit row. Both are RPCs carrying the caller's own OAuth token: since
// SB-595 the client is denied the audit table itself, and the record RPC accepts only
// the connection's own principal on its own client.
//
// Kept free of Deno globals so it runs under Node's --experimental-strip-types in CI
// (function-tests.yml), with the RPC injected.
//
// Rules this module guarantees (TC-SB600-6):
//   * a precheck refusal, or a precheck that cannot be read, stops the tool (fail closed);
//   * every call produces exactly one record attempt: allowed, denied or error;
//   * an audit failure never changes the answer the caller gets;
//   * nothing from the arguments reaches the audit body except a record_type from the
//     closed enum and a UUID project_id; reason codes must be identifiers.

export type Rpc = (fn: string, body: Record<string, unknown>) => Promise<unknown>;

export type Verdict = {
  allowed: boolean;
  reason_code: string | null;
  retry_after_seconds: number | null;
};

export type Outcome = "allowed" | "denied" | "error";

export type Classified = { outcome: "denied" | "error"; reason_code: string };

export type GuardedResult = {
  verdict: Verdict;
  outcome: Outcome;
  reason_code: string | null;
  result?: unknown;
  error?: unknown;
  audited: boolean;
};

const IDENT_RE = /^[a-z_]{1,64}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_RESULT_ROWS = 1000;

export const UNKNOWN_TOOL = "unknown_tool";
export const PRECHECK_UNAVAILABLE = "precheck_unavailable";

export function identOrNull(v: unknown): string | null {
  return typeof v === "string" && IDENT_RE.test(v) ? v : null;
}

export async function precheck(rpc: Rpc, connectionId: string, toolName: string): Promise<Verdict> {
  try {
    const rows = await rpc("external_connection_precheck", { p_connection_id: connectionId, p_tool_name: toolName });
    const row = (Array.isArray(rows) ? rows[0] : rows) as Record<string, unknown> | undefined;
    if (row && typeof row.allowed === "boolean") {
      return {
        allowed: row.allowed,
        reason_code: identOrNull(row.reason_code) ?? (row.allowed ? null : "denied"),
        retry_after_seconds: typeof row.retry_after_seconds === "number" ? row.retry_after_seconds : null,
      };
    }
  } catch {
    // fall through: a control that cannot be read must not be treated as a yes
  }
  return { allowed: false, reason_code: PRECHECK_UNAVAILABLE, retry_after_seconds: null };
}

export type AuditInput = {
  connectionId: string;
  toolName: string;
  readOnly: boolean;
  args: Record<string, unknown>;
  recordTypes: string[];
  outcome: Outcome;
  reasonCode: string | null;
  result?: unknown;
  traceId: string;
};

export function auditBody(i: AuditInput): Record<string, unknown> {
  const rt = i.args?.record_type;
  const pid = i.args?.project_id;
  const count = (i.result as Record<string, unknown> | undefined)?.count;
  return {
    p_connection_id: i.connectionId,
    p_tool_name: identOrNull(i.toolName) ?? UNKNOWN_TOOL,
    p_operation: i.readOnly ? "read" : "write",
    p_outcome: i.outcome,
    p_reason_code: identOrNull(i.reasonCode) ?? (i.outcome === "allowed" ? null : "error"),
    p_resource_name: typeof rt === "string" && i.recordTypes.includes(rt) ? rt : null,
    p_project_id: typeof pid === "string" && UUID_RE.test(pid) ? pid : null,
    p_result_rows: typeof count === "number" && Number.isInteger(count) ? Math.min(Math.max(count, 0), MAX_RESULT_ROWS) : null,
    p_trace_id: UUID_RE.test(i.traceId) ? i.traceId : null,
  };
}

export async function record(rpc: Rpc, body: Record<string, unknown>): Promise<boolean> {
  try {
    await rpc("external_connection_record", body);
    return true;
  } catch {
    return false;
  }
}

export type GuardedCallInput = {
  rpc: Rpc;
  connectionId: string;
  toolName: string;       // already mapped to UNKNOWN_TOOL by the caller if not a known tool
  readOnly: boolean;
  args: Record<string, unknown>;
  recordTypes: string[];
  traceId: string;
  run: () => Promise<unknown>;
  classify: (e: unknown) => Classified;
};

export async function guardedCall(o: GuardedCallInput): Promise<GuardedResult> {
  const base = { connectionId: o.connectionId, toolName: o.toolName, readOnly: o.readOnly, args: o.args, recordTypes: o.recordTypes, traceId: o.traceId };

  const verdict = await precheck(o.rpc, o.connectionId, o.toolName);
  if (!verdict.allowed) {
    const audited = await record(o.rpc, auditBody({ ...base, outcome: "denied", reasonCode: verdict.reason_code }));
    return { verdict, outcome: "denied", reason_code: verdict.reason_code, audited };
  }

  let result: unknown;
  try {
    result = await o.run();
  } catch (e) {
    const c = o.classify(e);
    const audited = await record(o.rpc, auditBody({ ...base, outcome: c.outcome, reasonCode: c.reason_code }));
    return { verdict, outcome: c.outcome, reason_code: c.reason_code, error: e, audited };
  }
  const audited = await record(o.rpc, auditBody({ ...base, outcome: "allowed", reasonCode: null, result }));
  return { verdict, outcome: "allowed", reason_code: null, result, audited };
}
