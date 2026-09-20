// F18 — an owner could not export the organization's data. Now an export
// request is built by this worker into a ZIP (one NDJSON per table) in the
// private `exports` bucket, and removed after it expires.
//
// Runs against a local Supabase (Storage included) with
// supabase/tests/fixtures loaded: organization A's fixture holds a secret in
// every place public.secrets covers (account token, agent key, tool
// credentials, media-preprocessing key) and a webhook token.
import "../_shared/testing/env.ts"; // before index.ts: keys are read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import { strFromU8, unzipSync } from "fflate";
import type { Database } from "../_shared/types/database_types.ts";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { handler } from "./index.ts";

const up = await supabaseIsUp();

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

type Client = ReturnType<typeof service>;

const TABLES = [
  "organizations",
  "organizations_addresses",
  "contacts_addresses",
  "conversations",
  "messages",
  "agents",
  "webhooks",
  "logs",
] as const;

// Everything that must never leave in an export: masks, key shapes and the
// fixture's actual secret values (supabase/tests/fixtures/seed_test.sql).
const FORBIDDEN = [
  "********",
  "sk_",
  "EAAG",
  "Bearer",
  "sk-test-secret-a",
  "AIza-test-secret-a",
  "P@ss-test-secret",
  "erp-test-secret",
  "mcp-test-secret",
  "test-webhook-token-a",
];

function run() {
  return handler(
    new Request("http://localhost/org-export", {
      method: "POST",
      headers: { authorization: `Bearer ${env.serviceRoleKey}` },
    }),
  );
}

async function exportRow(client: Client, id: string) {
  const { data } = await client
    .from("organization_exports")
    .select()
    .eq("id", id)
    .single()
    .throwOnError();
  return data;
}

/**
 * What the export is expected to hold: every row of the organization, minus
 * the simulator's (S1).
 *
 * The exclusion belongs HERE rather than in the assertion, because the
 * invariant this test pins has not changed — the export carries the whole
 * organization — and the filter has to be spelled the same way the exporter
 * spells it or the test would pass for the wrong reason.
 */
async function count(client: Client, table: (typeof TABLES)[number]) {
  const column = table === "organizations" ? "id" : "organization_id";
  let query = client
    .from(table)
    .select("*", { count: "exact", head: true })
    .eq(column, fixture.orgA);

  if (
    [
      "organizations_addresses",
      "contacts_addresses",
      "conversations",
      "messages",
      "logs",
    ].includes(table)
  ) {
    query = query.or("service.is.null,service.neq.sandbox");
  }

  const { count } = await query.throwOnError();

  return count ?? 0;
}

Deno.test({
  name:
    "F18: the worker exports organization A — one NDJSON per table, A's rows only, no secrets — and removes it after expiry",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const { data: job } = await client
      .from("organization_exports")
      .insert({ organization_id: fixture.orgA })
      .select()
      .single()
      .throwOnError();

    try {
      const unauthorized = await handler(
        new Request("http://localhost/org-export", { method: "POST" }),
      );
      assertEquals(unauthorized.status, 401);

      const response = await run();
      assertEquals(response.status, 200);

      const done = await exportRow(client, job.id);
      assertEquals(done.status, "ready", done.error ?? "");
      assertEquals(
        done.object_name,
        `organizations/${fixture.orgA}/exports/${job.id}.zip`,
      );

      const { data: blob, error } = await client.storage
        .from("exports")
        .download(done.object_name!);
      if (error) throw error;
      const files = unzipSync(new Uint8Array(await blob.arrayBuffer()));

      assertEquals(
        Object.keys(files).sort(),
        [...TABLES.map((t) => `${t}.ndjson`), "manifest.json"].sort(),
      );

      let everything = "";
      for (const table of TABLES) {
        const text = strFromU8(files[`${table}.ndjson`]);
        everything += text;
        const rows = text.split("\n").filter(Boolean).map((l) => JSON.parse(l));
        assertEquals(rows.length, await count(client, table), table);
        for (const row of rows) {
          assertEquals(
            table === "organizations" ? row.id : row.organization_id,
            fixture.orgA,
            `${table} holds another organization's row`,
          );
        }
      }
      assert(!everything.includes(fixture.orgB), "organization B leaked");
      for (const secret of FORBIDDEN) {
        assert(!everything.includes(secret), `the export contains ${secret}`);
      }
      assert(!everything.includes(env.serviceRoleKey));

      const manifest = JSON.parse(strFromU8(files["manifest.json"]));
      assertEquals(manifest.organization_id, fixture.orgA);
      assertEquals(manifest.counts.organizations, 1);

      // Expired: the file goes, the row says so.
      await client
        .from("organization_exports")
        .update({ expires_at: new Date(Date.now() - 1000).toISOString() })
        .eq("id", job.id)
        .throwOnError();
      await run();
      const expired = await exportRow(client, job.id);
      assertEquals(expired.status, "expired");
      assertEquals(expired.object_name, null);
      const { error: gone } = await client.storage
        .from("exports")
        .download(done.object_name!);
      assert(gone, "the expired file is still in Storage");
    } finally {
      await client.storage.from("exports").remove([
        `organizations/${fixture.orgA}/exports/${job.id}.zip`,
      ]);
      await client.from("organization_exports").delete().eq("id", job.id);
    }
  },
});

// S1 — a drill is not the organization's data.
//
// The export is scoped by organization_id and by nothing else, so when the
// simulator arrived every rehearsal started travelling in it: a member's
// test conversation and its messages, mixed into the same NDJSON as real
// customer traffic, for whoever reads the ZIP to tell apart. Webhooks
// already answered this question — `notify_webhook` drops any row whose
// service is `sandbox` — and the export now answers it the same way, so
// there is one rule for "is a sandbox row real?" instead of two.
Deno.test({
  name: "S1: the export carries no sandbox rows, and still carries the rest",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    const tester = "sim:export-check";

    // Unarmed, so no trigger wakes agent-client for a fixture row.
    const { data: drill } = await client
      .from("messages")
      .insert({
        organization_id: fixture.orgA,
        service: "sandbox",
        organization_address: fixture.orgA,
        conversation_address: tester,
        sender_address: tester,
        content: {
          version: "1",
          type: "text",
          kind: "text",
          text: "ensayo que no debe exportarse",
        },
        status: { delivered: new Date().toISOString() },
      })
      .select()
      .single()
      .throwOnError();

    // A log row that names NO service. `service <> 'sandbox'` is NULL for
    // this row, and NULL is not true, so a plain `neq` filter would drop it
    // from the export without a word — and most application errors name no
    // channel, so that would be most of the table.
    const { data: log } = await client
      .from("logs")
      .insert({
        organization_id: fixture.orgA,
        level: "error",
        category: "history",
        message: "sin servicio, y aun así exportable",
      })
      .select()
      .single()
      .throwOnError();

    const { data: job } = await client
      .from("organization_exports")
      .insert({ organization_id: fixture.orgA })
      .select()
      .single()
      .throwOnError();

    try {
      assertEquals((await run()).status, 200);

      const done = await exportRow(client, job.id);
      assertEquals(done.status, "ready", done.error ?? "");

      const { data: blob, error } = await client.storage
        .from("exports")
        .download(done.object_name!);
      if (error) throw error;
      const files = unzipSync(new Uint8Array(await blob.arrayBuffer()));

      const rowsOf = (table: (typeof TABLES)[number]) =>
        strFromU8(files[`${table}.ndjson`])
          .split("\n")
          .filter(Boolean)
          .map((line) => JSON.parse(line) as Record<string, unknown>);

      // Not the conversation, not the message, not the account, and not the
      // text either — a drill's content is as absent as its row.
      for (const table of TABLES) {
        for (const row of rowsOf(table)) {
          assert(
            row.service !== "sandbox",
            `${table} exported a sandbox row: ${JSON.stringify(row)}`,
          );
        }
      }

      assert(
        !strFromU8(files["messages.ndjson"]).includes(
          "ensayo que no debe exportarse",
        ),
        "the drill's text is in the export",
      );

      // The control: this excluded drills, not conversations. The fixture's
      // real whatsapp conversation and its messages are still there.
      const conversations = rowsOf("conversations");
      assert(
        conversations.some((row) => row.id === fixture.convA1),
        "the real conversation went missing with the drill",
      );
      assert(
        conversations.every((row) => row.organization_id === fixture.orgA),
        "another organization's conversation leaked",
      );
      assert(rowsOf("messages").length > 0, "messages came out empty");
      assert(
        rowsOf("organizations_addresses").some(
          (row) => row.service === "whatsapp",
        ),
        "the real account went missing with the sandbox one",
      );
      assert(
        rowsOf("logs").some((row) => row.id === log.id),
        "a log row with no service was dropped by the sandbox filter",
      );

      // The manifest counts what was written, so it agrees by construction;
      // asserted because an export whose manifest overcounts is worse than
      // one that simply excludes.
      const manifest = JSON.parse(strFromU8(files["manifest.json"]));
      assertEquals(manifest.counts.conversations, conversations.length);
      assertEquals(manifest.counts.messages, rowsOf("messages").length);
    } finally {
      await client.storage.from("exports").remove([
        `organizations/${fixture.orgA}/exports/${job.id}.zip`,
      ]);
      await client.from("organization_exports").delete().eq("id", job.id);
      await client
        .from("conversations")
        .delete()
        .eq("id", drill.conversation_id!)
        .throwOnError();
      await client.from("logs").delete().eq("id", log.id).throwOnError();
    }
  },
});
