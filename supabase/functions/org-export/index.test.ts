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

async function count(client: Client, table: (typeof TABLES)[number]) {
  const column = table === "organizations" ? "id" : "organization_id";
  const { count } = await client
    .from(table)
    .select("*", { count: "exact", head: true })
    .eq(column, fixture.orgA)
    .throwOnError();
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
