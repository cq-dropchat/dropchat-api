// §5.2 — the v0 → v1 conversion used by the backfill.
//
// cases.json holds, per v0 shape: the input, the v1 content the backfill
// writes (`expected`, null when it refuses), and — only where the two differ
// — what the UI's toV1 returns today (`ui`, recorded from open-bsp-ui
// src/supabase/messages-v0.ts; the UI checks it against the same file). The
// differences are the list below, each explained in messages_v0.ts.
import { assert, assertEquals } from "jsr:@std/assert@1";
import Ajv from "npm:ajv@8.17.1";
import { toV1Content } from "./messages_v0.ts";
import { SCHEMA_PATH } from "./contracts/generate.ts";

type Case = { input: unknown; expected: unknown; ui?: unknown };

const cases: Record<string, Case> = JSON.parse(
  await Deno.readTextFile(
    new URL("./__fixtures__/messages_v0/cases.json", import.meta.url),
  ),
);

Deno.test("v0 → v1: every recorded shape converts to its expected content", () => {
  for (const [name, { input, expected }] of Object.entries(cases)) {
    const result = toV1Content(input);
    assertEquals(
      result.ok ? JSON.parse(JSON.stringify(result.content)) : null,
      expected,
      name,
    );
    if (!result.ok) assert(result.reason, `${name}: no reason given`);
  }
});

Deno.test("v0 → v1: the backfill departs from the UI's toV1 only where intended", () => {
  assertEquals(
    Object.entries(cases).filter(([, c]) => "ui" in c).map(([name]) => name)
      .sort(),
    [
      "media_placeholder", // v1 has it; the UI could not convert it
      "reaction", // keeps re_message_id
      "tool_result_data", // record-only trace, not spoken text
      "tool_result_text",
      "tool_use_data", // record-only trace, not a `function` data part
      "tool_use_text",
    ],
  );
});

Deno.test("v0 → v1: every converted content satisfies the v1 contract", async () => {
  // deno-lint-ignore no-explicit-any
  const ajv = new (Ajv as any)({ strict: false, allErrors: true });
  const validate = ajv.compile(
    JSON.parse(await Deno.readTextFile(SCHEMA_PATH)),
  );
  for (const [name, { expected }] of Object.entries(cases)) {
    if (expected === null) continue;
    assert(
      validate(expected),
      `${name}: ${JSON.stringify(validate.errors?.slice(0, 3))}`,
    );
  }
});

Deno.test("v0 → v1: v1 content and non-objects are refused", () => {
  assertEquals(
    toV1Content({ version: "1", type: "text", kind: "text", text: "x" }).ok,
    false,
  );
  assertEquals(toV1Content("texto").ok, false);
  assertEquals(toV1Content(null).ok, false);
  assertEquals(
    toV1Content({
      type: "function",
      v1_type: "data",
      id: "c",
      function: { name: "f", arguments: "{no json" },
    }),
    { ok: false, reason: "tool use with non-JSON data" },
  );
});
