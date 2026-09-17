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
