// §5.2 — the backfill end to end, on the local database: v0 rows of every
// recorded shape (fixtures/messages_v0/cases.json) are inserted the way they
// exist in production (the check constraint is NOT VALID for them), then
// dry-run, backfilled, re-run, and the constraint is validated.
import "../_shared/testing/env.ts";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import postgres from "postgres";
import { env, fixture, supabaseIsUp } from "../_shared/testing/env.ts";
import { backfillMessagesV1 } from "./backfill_messages_v1.ts";

const up = await supabaseIsUp();

type Case = { input: unknown; expected: unknown };
const cases: Record<string, Case> = JSON.parse(
  await Deno.readTextFile(
    new URL("../_shared/__fixtures__/messages_v0/cases.json", import.meta.url),
  ),
);

const CONSTRAINT = `
  alter table public.messages add constraint messages_content_schema check (
    content = '{}'::jsonb
    or (
      content->>'version' is not null
      and content->>'type' in ('text', 'file', 'data')
      and content->>'kind' is not null
    )
  )`;

Deno.test({
  name:
    "§5.2: backfill converts every recorded v0 shape, refuses the rest, and lets the constraint validate",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const sql = postgres(
      "postgresql://postgres:postgres@127.0.0.1:54322/postgres", // local default
      { max: 1, onnotice: () => {} },
    );
    const client = createClient(env.url, env.serviceRoleKey, {
      auth: { persistSession: false },
    });
    const ids: Record<string, string> = {};

    try {
      await sql.unsafe(
        "alter table public.messages drop constraint messages_content_schema",
      );
      for (const [name, { input }] of Object.entries(cases)) {
        const [row] = await sql`
          insert into public.messages (
            organization_id, service, organization_address,
            conversation_address, sender_address, content, status,
            timestamp, created_at, updated_at
          ) values (
            ${fixture.orgA}, 'whatsapp', ${fixture.waA}, ${fixture.contactA1},
            ${fixture.contactA1}, ${sql.json(input as never)},
            '{"delivered": "2025-01-01T00:00:00Z"}',
            '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z',
            '2025-01-01T00:00:00Z'
          ) returning id`;
        ids[name] = row.id;
      }
      await sql.unsafe(CONSTRAINT + " not valid");

      const convertible = Object.values(cases).filter((c) => c.expected)
        .length;
      const refusedNames = Object.entries(cases).filter(([, c]) => !c.expected)
        .map(([n]) => n);

      // Dry run: a report, no writes.
      const dry = await backfillMessagesV1(client, {
        dryRun: true,
        batchSize: 7,
      });
      assertEquals(dry.converted, convertible);
      assertEquals(dry.written, 0);
      assertEquals(
        dry.refused.map((r) => r.id).sort(),
        refusedNames.map((n) => ids[n]).sort(),
      );
      const [{ v0 }] = await sql`
        select count(*)::int as v0 from public.messages
        where content->>'version' is null and content <> '{}'`;
      assertEquals(v0, Object.keys(cases).length);

      // The real run, in small batches.
      const run = await backfillMessagesV1(client, { batchSize: 7 });
      assertEquals(run.written, convertible);

      for (const [name, { expected }] of Object.entries(cases)) {
        const [row] = await sql`
          select content, updated_at from public.messages where id = ${
          ids[name]
        }`;
        assertEquals(
          row.content,
          expected ?? cases[name].input,
          `${name}: stored content`,
        );
        assertEquals(
          new Date(row.updated_at).toISOString(),
          "2025-01-01T00:00:00.000Z",
          `${name}: updated_at moved`,
        );
      }

      // Idempotent.
      const again = await backfillMessagesV1(client, { batchSize: 7 });
      assertEquals(again.written, 0);
      assertEquals(again.refused.length, refusedNames.length);

      // Once the refused rows are dealt with, the constraint validates.
      await sql`delete from public.messages where id in ${
        sql(refusedNames.map((n) => ids[n]))
      }`;
      await sql.unsafe(
        "alter table public.messages validate constraint messages_content_schema",
      );
      const [{ valid }] = await sql`
        select convalidated as valid from pg_constraint
        where conname = 'messages_content_schema'`;
      assert(valid);
    } finally {
      await sql`delete from public.messages where id in ${
        sql(
          Object.values(ids).length
            ? Object.values(ids)
            : [crypto.randomUUID()],
        )
      }`;
      // Back to the declared state: NOT VALID.
      await sql.unsafe(
        "alter table public.messages drop constraint if exists messages_content_schema",
      );
      await sql.unsafe(CONSTRAINT + " not valid");
      await sql.end();
    }
  },
});
