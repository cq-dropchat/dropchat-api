// F26 — logs were `console.*` with `%c` colour escapes: no JSON, no
// request id, no organization. A message could not be followed across the
// five functions that touch it.
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import * as log from "./logger.ts";
import { withRequestLogging } from "./logger.ts";

function captureConsole() {
  const lines: string[] = [];
  const original = {
    log: console.log,
    warn: console.warn,
    error: console.error,
    info: console.info,
  };
  for (const level of ["log", "warn", "error", "info"] as const) {
    console[level] = (...args: unknown[]) => {
      lines.push(args.map(String).join(" "));
    };
  }
  return {
    lines,
    restore: () => Object.assign(console, original),
  };
}

Deno.test("F26: a log line is one JSON object with level, message and details", () => {
  const out = captureConsole();
  try {
    log.warn("Dispatch failed", { message_id: "m1", code: 130429 });
  } finally {
    out.restore();
  }

  assertEquals(out.lines.length, 1);
  const line = JSON.parse(out.lines[0]);
  assertEquals(line.level, "warn");
  assertEquals(line.msg, "Dispatch failed");
  assertEquals(line.message_id, "m1");
  assertEquals(line.code, 130429);
  assertMatch(line.ts, /^\d{4}-\d{2}-\d{2}T/);
  assert(!out.lines[0].includes("%c"));
});

Deno.test("F26: lines inside a request carry its request_id and function name", async () => {
  const out = captureConsole();
  let seen: string | null = null;
  try {
    const handler = withRequestLogging("whatsapp-dispatcher", async (req) => {
      log.info("inside", { organization_id: "org-1" });
      await Promise.resolve();
      log.error("after an await", new Error("boom"));
      seen = req.headers.get("x-request-id");
      return new Response("ok");
    });

    const response = await handler(
      new Request("http://localhost/x", {
        headers: { "x-request-id": "req-123" },
      }),
    );
    assertEquals(response.headers.get("x-request-id"), "req-123");
  } finally {
    out.restore();
  }

  const lines = out.lines.map((l) => JSON.parse(l));
  assertEquals(seen, "req-123");
  for (const line of lines) {
    assertEquals(line.request_id, "req-123");
    assertEquals(line.fn, "whatsapp-dispatcher");
  }
  assertEquals(lines[0].organization_id, "org-1");
  assertEquals(
    lines.find((l) => l.msg === "after an await").error.message,
    "boom",
  );
  // The wrapper also logs completion with status and duration.
  const done = lines.find((l) => l.msg === "request completed");
  assert(done, "no completion line");
  assertEquals(done.status, 200);
  assert(typeof done.duration_ms === "number");
});

Deno.test("F26: a request without x-request-id gets a fresh one", async () => {
  const out = captureConsole();
  try {
    const handler = withRequestLogging(
      "fn",
      () => Promise.resolve(new Response()),
    );
    const response = await handler(new Request("http://localhost/x"));
    assertMatch(response.headers.get("x-request-id") ?? "", /^[0-9a-f-]{36}$/);
  } finally {
    out.restore();
  }
});

Deno.test("F26: string details stay readable", () => {
  const out = captureConsole();
  try {
    log.error("Error converting", "bad input");
  } finally {
    out.restore();
  }
  assertEquals(JSON.parse(out.lines[0]).details, "bad input");
});

Deno.test("operational events allowlist fields and preserve release/correlation", async () => {
  const out = captureConsole();
  try {
    await log.withRequestLogging("worker", () => {
      log.event("persist.completed", "success", {
        message_id: "m1",
        duration_ms: 12,
        access_token: "secret",
        payload: { text: "private" },
      });
      return new Response();
    })(
      new Request("http://localhost", { headers: { "x-request-id": "chain" } }),
    );
  } finally {
    out.restore();
  }
  const event = out.lines.map((line) => JSON.parse(line)).find((line) =>
    line.event === "persist.completed"
  );
  assertEquals(event.request_id, "chain");
  assertEquals(event.message_id, "m1");
  assertEquals(event.duration_ms, 12);
  assertEquals(event.access_token, undefined);
  assertEquals(event.payload, undefined);
  assertEquals(event.release, "unknown");
});

Deno.test("event floods are bounded, report lost samples and cannot break processing", () => {
  const out = captureConsole();
  const saved = Date.now;
  const sample = Deno.env.get("TELEMETRY_SUCCESS_SAMPLE_RATE");
  let now = saved() + 120000;
  Date.now = () => now;
  Deno.env.set("TELEMETRY_SUCCESS_SAMPLE_RATE", "1");
  try {
    for (let n = 0; n < 1000; n++) {
      log.event("media.completed", "success", { duration_ms: 1 });
    }
    for (let n = 0; n < 200; n++) {
      log.event("media.completed", "failure", { error_class: "injected" });
    }
    const budget = log.telemetryBudget();
    assertEquals(budget.successes, 600);
    assertEquals(budget.failures, 100);
    assertEquals(budget.limited, 500);
    assertEquals(budget.complete_business_window, false);
    now += 60000;
    log.event("media.completed", "success");
    assert(
      out.lines.some((line) => JSON.parse(line).event === "telemetry.budget"),
    );
    console.log = () => {
      throw new Error("collector broken");
    };
    log.event("media.completed", "failure");
  } finally {
    Date.now = saved;
    out.restore();
    if (sample === undefined) Deno.env.delete("TELEMETRY_SUCCESS_SAMPLE_RATE");
    else Deno.env.set("TELEMETRY_SUCCESS_SAMPLE_RATE", sample);
  }
});
Deno.test("untrusted job headers cannot impersonate cron correlation", async () => {
  const out = captureConsole();
  try {
    await log.withRequestLogging("worker", () => new Response())(
      new Request("http://localhost", {
        headers: { "x-job-id": "a".repeat(36), "x-job-attempt": "1" },
      }),
    );
  } finally {
    out.restore();
  }
  assertEquals(JSON.parse(out.lines.at(-1)!).job_id, undefined);
});
