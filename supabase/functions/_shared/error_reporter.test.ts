import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { canReport, toIssue } from "./error_reporter.ts";

// E1. What a log line becomes on its way to public.error_issues.
//
// The interesting half is the title. `msg` is the stable label the caller
// chose and the Error's message is the part that changes per occurrence;
// joining them is what lets normalize_error_message strip the varying ids and
// still leave a sentence that reads.

Deno.test("E1: an error's name and message become the issue's kind and title", () => {
  const issue = toIssue({
    ts: "2026-09-20T00:00:00.000Z",
    level: "error",
    fn: "whatsapp-dispatcher",
    msg: "Dispatch failed",
    error: {
      name: "TypeError",
      message: "invalid token",
      stack: "TypeError: invalid token\n  at send",
    },
  });

  assertEquals(issue.kind, "TypeError");
  assertEquals(issue.message, "Dispatch failed: invalid token");
  assertEquals(issue.culprit, "whatsapp-dispatcher");
  assertStringIncludes(issue.stack ?? "", "at send");
});

Deno.test("E1: a line with no Error still reports, as a plain Error", () => {
  const issue = toIssue({
    level: "error",
    fn: "mcp",
    msg: "Unhandled error on POST /tools",
  });

  assertEquals(issue.kind, "Error");
  assertEquals(issue.message, "Unhandled error on POST /tools");
  assertEquals(issue.stack, undefined);
});

// The label is not repeated when the Error carries the same text: a title
// reading "invalid token: invalid token" helps nobody.
Deno.test("E1: a message identical to the label is not doubled", () => {
  const issue = toIssue({
    level: "error",
    msg: "invalid token",
    error: { name: "Error", message: "invalid token" },
  });

  assertEquals(issue.message, "invalid token");
});

Deno.test("E1: the rest of the line is kept as context", () => {
  const issue = toIssue({
    ts: "2026-09-20T00:00:00.000Z",
    level: "error",
    fn: "whatsapp-webhook",
    request_id: "11111111-2222-3333-4444-555555555555",
    msg: "boom",
    organization_id: "org-1",
    code: 130429,
  });

  assertEquals(issue.context, {
    request_id: "11111111-2222-3333-4444-555555555555",
    organization_id: "org-1",
    code: 130429,
  });
});

// A log line may hold whatever a caller spread into it. console.error prints a
// BigInt or a cycle without complaint; supabase-js would throw on either, and
// a throw here would turn a handled failure into an unhandled one.
Deno.test("E1: a context that is not plain JSON survives the trip", () => {
  const cyclic: Record<string, unknown> = { name: "loop" };
  cyclic.self = cyclic;

  const issue = toIssue({
    level: "error",
    msg: "boom",
    attempts: 9007199254740993n,
    cyclic,
  });

  assertEquals(issue.context, {
    attempts: "9007199254740993",
    cyclic: { name: "loop", self: "[circular]" },
  });
});

// Opt-in, and off wherever there is nothing to report to — `deno test` and
// `deno check` among them, which is why the suite above never opens a client.
Deno.test("E1: reporting needs the switch, a project url and a service key", () => {
  const env = (vars: Record<string, string>) => ({
    get: (key: string) => vars[key],
  });

  assertEquals(canReport(env({}) as unknown as typeof Deno.env), false);

  // Credentials alone are not consent: this is the state every test run and
  // every local script is in.
  assertEquals(
    canReport(
      env({
        SUPABASE_URL: "http://x",
        SUPABASE_SERVICE_ROLE_KEY: "k",
      }) as unknown as typeof Deno.env,
    ),
    false,
  );

  // Nor is the switch enough on its own.
  assertEquals(
    canReport(
      env({ ERROR_REPORTING: "on" }) as unknown as typeof Deno.env,
    ),
    false,
  );

  assertEquals(
    canReport(
      env({
        ERROR_REPORTING: "on",
        SUPABASE_URL: "http://x",
        SUPABASE_SERVICE_ROLE_KEY: "k",
      }) as unknown as typeof Deno.env,
    ),
    true,
  );

  // The dictionary that replaces the legacy key counts too.
  assertEquals(
    canReport(
      env({
        ERROR_REPORTING: "on",
        SUPABASE_URL: "http://x",
        SUPABASE_SECRET_KEYS: "{}",
      }) as unknown as typeof Deno.env,
    ),
    true,
  );
});

// The switch is what turns it on, and only the exact value does.
Deno.test("E1: any value other than on leaves reporting off", () => {
  const env = {
    get: (key: string) =>
      ({
        ERROR_REPORTING: "true",
        SUPABASE_URL: "http://x",
        SUPABASE_SERVICE_ROLE_KEY: "k",
      })[key],
  };

  assertEquals(canReport(env as unknown as typeof Deno.env), false);
});
