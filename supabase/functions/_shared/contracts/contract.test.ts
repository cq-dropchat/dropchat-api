// F29 — `openapi.json` is PostgREST's dump of the public schema ("standard
// public schema", version 13.0.4): it types `messages.content` as `jsonb`.
// Nothing versioned described the content format integrators write and read.
//
// contracts/message-content.v1.schema.json is that contract, generated from
// the types the functions compile against. These tests fail when a type
// change was not regenerated, and pin what the schema accepts and refuses.
import "../testing/env.ts";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import Ajv from "npm:ajv@8.17.1";
import { env, supabaseIsUp } from "../testing/env.ts";
import { generateContentSchema, SCHEMA_PATH } from "./generate.ts";

const committed = await Deno.readTextFile(SCHEMA_PATH).catch(() => "");

function validator() {
  // deno-lint-ignore no-explicit-any
  const ajv = new (Ajv as any)({ strict: false, allErrors: true });
  return ajv.compile(JSON.parse(committed));
}

Deno.test("F29: the committed content schema matches the types", () => {
  assert(committed, "contracts/message-content.v1.schema.json is missing");
  assertEquals(
    committed,
    generateContentSchema(),
    "stale: run `deno task contracts` and commit contracts/",
  );
});

const VALID: Record<string, unknown> = {
  text: { version: "1", type: "text", kind: "text", text: "hola" },
  image: {
    version: "1",
    type: "file",
    kind: "image",
    file: {
      uri: "internal://media/organizations/x/attachments/y",
      mime_type: "image/jpeg",
      size: 1024,
    },
    text: "caption",
  },
  reaction: {
    version: "1",
    type: "data",
    kind: "reaction",
    re_message_id: "wamid.X",
    data: { action: "added", unicode: "👍" },
  },
  location: {
    version: "1",
    type: "data",
    kind: "location",
    data: {
      address: "Av. Corrientes 1234",
      name: "Oficina",
      latitude: -34.6,
      longitude: -58.4,
    },
  },
  template: {
    version: "1",
    type: "data",
    kind: "template",
    data: {
      name: "hello_world",
      language: { code: "es", policy: "deterministic" },
    },
  },
  media_placeholder: {
    version: "1",
    type: "data",
    kind: "media_placeholder",
    data: {},
    file: { mime_type: "image/jpeg", size: 10 },
  },
  tool_trace: {
    version: "1",
    type: "data",
    kind: "data",
    data: { rows: 3 },
    internal: true,
    tool: {
      provider: "local",
      type: "sql",
      label: "erp-db",
      name: "query",
      use_id: "u1",
      event: "result",
    },
  },
};

const INVALID: Record<string, unknown> = {
  "reaction without action": {
    version: "1",
    type: "data",
    kind: "reaction",
    data: { reaction: "👍" },
  },
  "v0 (no version)": { type: "text", text: "hola" },
  "unknown version": { version: "2", type: "text", kind: "text", text: "x" },
  "text without text": { version: "1", type: "text", kind: "text" },
  "file without uri": {
    version: "1",
    type: "file",
    kind: "image",
    file: { mime_type: "image/jpeg" },
  },
  "unknown type": { version: "1", type: "bogus", kind: "text", text: "x" },
};

Deno.test("F29: the schema accepts each content kind", () => {
  const validate = validator();
  for (const [name, content] of Object.entries(VALID)) {
    assert(
      validate(content),
      `${name} refused: ${JSON.stringify(validate.errors?.slice(0, 3))}`,
    );
  }
});

Deno.test("F29: the schema refuses malformed and legacy content", () => {
  const validate = validator();
  for (const [name, content] of Object.entries(INVALID)) {
    assertEquals(validate(content), false, `${name} was accepted`);
  }
});

Deno.test({
  name: "F29: every v1 content in the local database matches the schema",
  ignore: !(await supabaseIsUp()),
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = createClient(env.url, env.serviceRoleKey, {
      auth: { persistSession: false },
    });
    const { data } = await client
      .from("messages")
      .select("id, content")
      .eq("content->>version", "1")
      .limit(5000)
      .throwOnError();

    const validate = validator();
    const refused = data.filter((row) => !validate(row.content));
    assertEquals(
      refused.map((r) => r.id),
      [],
      `stored contents the contract refuses: ${
        JSON.stringify(refused.slice(0, 2).map((r) => r.content))
      }`,
    );
  },
});
