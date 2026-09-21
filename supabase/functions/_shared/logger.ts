// Structured logs (F26). One JSON object per line:
//
//   {"ts":"…","level":"warn","fn":"whatsapp-dispatcher","request_id":"…",
//    "msg":"Dispatch failed","message_id":"…","code":130429}
//
// Object details are spread into the line (so `organization_id`,
// `conversation_id`, `message_id` become top-level, queryable fields);
// strings go under `details`; Errors under `error` with name, message and
// stack. Inside a handler wrapped with withRequestLogging every line carries
// the function name and the request id — taken from `x-request-id` when the
// caller sent one (so a chain of functions shares it), minted otherwise, and
// echoed on the response.
//
// Replaces console.* with `%c` colour escapes, which Supabase's log explorer
// showed as literal text and nothing could filter on.
import { AsyncLocalStorage } from "node:async_hooks";
import { hasWaitUntil, waitUntil } from "./edge_runtime.ts";

type LogLevel = "info" | "warn" | "error";

type RequestLogContext = { fn: string; request_id: string };

const storage = new AsyncLocalStorage<RequestLogContext>();

function serializeError(error: Error) {
  return { name: error.name, message: error.message, stack: error.stack };
}

function toFields(details: unknown): Record<string, unknown> {
  if (details == null) return {};
  if (details instanceof Error) return { error: serializeError(details) };
  if (typeof details !== "object" || Array.isArray(details)) {
    return { details };
  }
  const fields: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(details)) {
    fields[key] = value instanceof Error ? serializeError(value) : value;
  }
  return fields;
}

/**
 * JSON for a value that was never meant to be JSON: BigInt becomes a string
 * and a cycle becomes "[circular]" instead of throwing. Exported because
 * error_reporter.ts needs the same guarantee for the same values — a log line
 * that can be printed has to be one that can also be stored.
 */
export function safeStringify(line: Record<string, unknown>): string {
  const seen = new WeakSet();
  return JSON.stringify(line, (_key, value) => {
    if (typeof value === "bigint") return value.toString();
    if (typeof value === "object" && value !== null) {
      if (seen.has(value)) return "[circular]";
      seen.add(value);
    }
    return value;
  });
}

// E1. Every error line is also an occurrence of an issue in the panel
// (error_reporter.ts). Imported lazily, and only when an error actually
// happens: error_reporter pulls in supabase-js, whose client imports this
// module back for the request id, so a static import here would be a cycle —
// and an invocation that never errors would pay to load it for nothing.
//
// Fire and forget, after the response: reporting an error must never delay or
// break the handling of it. A rejection is swallowed here rather than logged,
// because the thing that would log it is this function.
//
// Two gates, and both are checked HERE rather than inside the reporter,
// because what has to be avoided is deferring anything at all — not just
// skipping the request once deferred. The Meta webhook tests read "something
// was deferred" as "the payload was accepted", so a report queued from an
// error path makes an invalid signature look accepted.
//
//   ERROR_REPORTING=on   opt-in, set as a project secret (error_reporter.ts
//                        explains why this is not the default).
//   hasWaitUntil()       only where there IS an "after the response" — the
//                        deployed runtime and `supabase functions serve`.
//                        Logging is synchronous and has nothing to await on,
//                        so anywhere else the request would be a promise
//                        nobody owns, outliving its caller.
function report(line: Record<string, unknown>): void {
  try {
    if (Deno.env.get("ERROR_REPORTING") !== "on") return;
  } catch {
    // No --allow-env: nothing to report to either.
    return;
  }

  if (!hasWaitUntil()) return;

  try {
    waitUntil(
      import("./error_reporter.ts")
        .then((reporter) => reporter.captureError(line))
        .catch(() => {}),
    );
  } catch {
    // Reporting is best-effort by construction.
  }
}

function log(level: LogLevel, message: string, details?: unknown): void {
  const line = {
    ts: new Date().toISOString(),
    level,
    ...storage.getStore(),
    msg: message,
    ...toFields(details),
  };

  const method = level === "info" ? "log" : level;
  console[method](safeStringify(line));

  if (level === "error") report(line);
}

export function info(message: string, details?: unknown): void {
  log("info", message, details);
}

export function warn(message: string, details?: unknown): void {
  log("warn", message, details);
}

export function error(message: string, details?: unknown): void {
  log("error", message, details);
}

/** The request id of the current handler invocation, if any. */
export function currentRequestId(): string | undefined {
  return storage.getStore()?.request_id;
}

/**
 * Wraps an Edge Function handler: every log line inside carries `fn` and
 * `request_id`, the response echoes `x-request-id`, and completion is
 * logged with status and duration.
 */
export function withRequestLogging(
  fn: string,
  handler: (req: Request) => Response | Promise<Response>,
): (req: Request) => Promise<Response> {
  return (req) => {
    const request_id = req.headers.get("x-request-id") || crypto.randomUUID();
    const started = performance.now();

    return storage.run({ fn, request_id }, async () => {
      try {
        const response = await handler(req);
        info("request completed", {
          method: req.method,
          status: response.status,
          duration_ms: Math.round(performance.now() - started),
        });
        try {
          response.headers.set("x-request-id", request_id);
        } catch {
          // Immutable headers (e.g. a Response.redirect): the log has it.
        }
        return response;
      } catch (err) {
        error("request failed", {
          method: req.method,
          duration_ms: Math.round(performance.now() - started),
          error: err instanceof Error ? err : String(err),
        });
        throw err;
      }
    });
  };
}
