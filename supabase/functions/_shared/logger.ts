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
import { isServiceToken } from "./service_auth.ts";

type LogLevel = "info" | "warn" | "error";

type RequestLogContext = {
  fn?: string;
  request_id?: string;
  job_id?: string;
  attempt?: number;
};

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

function release(): string {
  try {
    return Deno.env.get("API_RELEASE") || "unknown";
  } catch {
    return "unknown";
  }
}

function log(level: LogLevel, message: string, details?: unknown): void {
  const line = {
    ts: new Date().toISOString(),
    level,
    ...storage.getStore(),
    release: release(),
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

    const context: RequestLogContext = { fn, request_id };
    try {
      if (
        isServiceToken(req.headers.get("authorization")?.replace("Bearer ", ""))
      ) {
        const job = req.headers.get("x-job-id");
        const attempt = Number(req.headers.get("x-job-attempt"));
        if (
          job && /^[a-f0-9-]{36}$/.test(job) && Number.isInteger(attempt) &&
          attempt > 0 && attempt <= 5
        ) {
          context.job_id = job;
          context.attempt = attempt;
        }
      }
    } catch { /* Missing environment permission must not block a handler. */ }
    return storage.run(context, async () => {
      if (context.job_id) {
        const wait = Number(req.headers.get("x-queue-wait-ms"));
        event("queue.started", "started", {
          duration_ms: Number.isFinite(wait) && wait >= 0 ? wait : 0,
        });
      }
      try {
        const response = await handler(req);
        info("request completed", {
          event: "http.completed",
          outcome: response.ok ? "success" : "failure",
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
          event: "http.failed",
          outcome: "failure",
          method: req.method,
          duration_ms: Math.round(performance.now() - started),
          error: err instanceof Error ? err : String(err),
        });
        throw err;
      }
    });
  };
}

/** Operational telemetry never includes payloads, credentials or text. */
const EVENT_FIELDS = new Set([
  "organization_id",
  "conversation_id",
  "message_id",
  "job_id",
  "attempt",
  "provider",
  "duration_ms",
  "status",
  "code",
  "count",
  "deferred",
  "error_class",
]);
let eventWindow = 0;
let successCount = 0;
let failureCount = 0;
let sampled = 0;
let limited = 0;
export function telemetryBudget() {
  return {
    window_start: eventWindow,
    successes: successCount,
    failures: failureCount,
    sampled,
    limited,
    complete_business_window: sampled === 0 && limited === 0,
  };
}
export function event(
  name: string,
  outcome:
    | "success"
    | "failure"
    | "started"
    | "accepted"
    | "delivered"
    | "skipped",
  details: Record<string, unknown> = {},
): void {
  try {
    const now = Date.now();
    if (now - eventWindow >= 60_000 || now < eventWindow) {
      if (sampled || limited) {
        log("warn", "telemetry window incomplete", {
          event: "telemetry.budget",
          ...telemetryBudget(),
        });
      }
      eventWindow = now;
      successCount =
        failureCount =
        sampled =
        limited =
          0;
    }
    // Configurable success sampling; failures have their own existing reporter.
    const configured = Number(
      Deno.env.get("TELEMETRY_SUCCESS_SAMPLE_RATE") ?? "1",
    );
    const rate = Number.isFinite(configured)
      ? Math.max(0, Math.min(1, configured))
      : 1;
    if (outcome !== "failure" && Math.random() >= rate) {
      sampled++;
      return;
    }
    if (outcome === "failure" ? failureCount >= 100 : successCount >= 600) {
      limited++;
      return;
    }
    if (outcome === "failure") failureCount++;
    else successCount++;
    const safe = Object.fromEntries(
      Object.entries(details).filter(([key, value]) =>
        EVENT_FIELDS.has(key) &&
        ["string", "number", "boolean"].includes(typeof value)
      ),
    );
    log(outcome === "failure" ? "error" : "info", name, {
      ...safe,
      event: name,
      outcome,
    });
  } catch {
    /* Observation cannot break processing, including a failed collector. */
  }
}

export function withJobLogging<T>(
  job_id: string,
  attempt: number,
  work: () => Promise<T>,
): Promise<T> {
  return storage.run({ ...storage.getStore(), job_id, attempt }, work);
}
