// E1. Turns an `error` log line into a row in public.error_issues.
//
// The hook is log.error (logger.ts), which every Edge Function already funnels
// through — the Hono onError handlers, the webhooks' `.catch()`, and
// withRequestLogging's own catch for anything that escapes. So nothing had to
// be instrumented function by function: what was already worth a log line is
// what lands in the panel.
//
// Imported dynamically by logger.ts, for two reasons. It breaks the cycle
// (supabase_client.ts imports logger.ts for the request id), and it keeps the
// cost at zero for an invocation that never errors: a function that logs no
// error never loads supabase-js on this path.
import { createUnsecureClient } from "./supabase_client.ts";
import * as log from "./logger.ts";
import { safeStringify } from "./logger.ts";
import type { Json } from "./types/database_types.ts";

type SerializedError = { name?: string; message?: string; stack?: string };

/** A line as logger.ts builds it, before it is stringified. */
export type ErrorLine = Record<string, unknown> & { msg?: unknown };

// Not a constant: `deno test` stubs the environment between cases, and a
// client captured at module load would outlive the stub.
let client: ReturnType<typeof createUnsecureClient> | undefined;

function reportingClient() {
  client ??= createUnsecureClient();
  return client;
}

/**
 * Opt-in: reporting happens only where `ERROR_REPORTING=on` was set (a
 * Supabase secret on the project), plus the credentials to reach the project.
 *
 * On by default would have been more convenient and is the wrong default. This
 * hooks log.error, which every function reaches on every failure, so "on
 * wherever the environment has credentials" means the test suite, a local
 * script and anything else that imports the logger start writing rows to
 * whatever project the environment happens to name. It also silently changed
 * what the Meta webhook tests measure: they equate deferred work with "the
 * payload was accepted", and a report deferred from an error path made an
 * invalid signature look accepted. A switch that has to be thrown on purpose
 * is also a switch that can be thrown off in seconds, without a deploy, if the
 * panel ever misbehaves in production.
 */
export function canReport(env = Deno.env): boolean {
  if (env.get("ERROR_REPORTING") !== "on") return false;
  if (!env.get("SUPABASE_URL")) return false;
  return Boolean(
    env.get("SUPABASE_SERVICE_ROLE_KEY") || env.get("SUPABASE_SECRET_KEYS"),
  );
}

function isSerializedError(value: unknown): value is SerializedError {
  return typeof value === "object" && value !== null &&
    ("message" in value || "name" in value || "stack" in value);
}

/**
 * The log line, split into the four things an issue is made of.
 *
 * `msg` is the stable half — the label the caller chose, the same on every
 * occurrence — and the error's own message is the varying half. Joining them
 * is what makes a useful title ("Dispatch failed: invalid token for 56912…")
 * survive fingerprinting: normalize_error_message strips the number, and what
 * is left groups every instance of that failure into one row.
 */
export function toIssue(line: ErrorLine): {
  kind: string;
  message: string;
  culprit: string | undefined;
  stack: string | undefined;
  context: Json;
} {
  const { ts: _ts, level: _level, fn, msg, error, ...rest } = line;
  const serialized = isSerializedError(error) ? error : undefined;

  const label = typeof msg === "string" && msg ? msg : "unknown error";
  const detail = serialized?.message;

  return {
    kind: serialized?.name || "Error",
    message: detail && detail !== label ? `${label}: ${detail}` : label,
    // The Edge Function's name. A stack's top frame would be more precise and
    // far less stable: bundled Edge Function stacks move with every deploy, so
    // fingerprinting on one would file the same bug afresh after each release.
    culprit: typeof fn === "string" ? fn : undefined,
    stack: serialized?.stack ?? undefined,
    // Whatever the caller spread into the line: organization_id, message_id,
    // the carrier's error code. Not filtered — these lines are already written
    // to stdout, so this adds no exposure, and the one field that would be
    // worth redacting (a token) has never belonged in a log line either.
    //
    // Round-tripped through the logger's stringifier rather than passed
    // straight to the client: these values reached us as arbitrary details,
    // and supabase-js would throw on a BigInt or a cycle that console.error
    // prints happily.
    context: JSON.parse(safeStringify(rest)) as Json,
  };
}

/**
 * Never throws and never blocks the response: reporting an error must not be
 * able to turn a handled failure into an unhandled one. A failure here is a
 * warning, deliberately not an error — log.error is what called us, and
 * answering it with another log.error is a loop.
 */
export async function captureError(line: ErrorLine): Promise<void> {
  if (!canReport()) return;

  try {
    const issue = toIssue(line);

    const { error } = await reportingClient().rpc("report_edge_error", {
      _kind: issue.kind,
      _message: issue.message,
      _culprit: issue.culprit,
      _stack: issue.stack,
      _context: issue.context,
    });

    if (error) log.warn("Could not report an error issue", { error });
  } catch (error) {
    log.warn("Could not report an error issue", { error });
  }
}
