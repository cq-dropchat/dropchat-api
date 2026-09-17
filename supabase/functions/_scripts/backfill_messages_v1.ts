// §5.2 — backfill of the messages whose content predates the v1 schema.
//
// Converts each v0 content with _shared/messages_v0.ts, checks the result
// against contracts/message-content.v1.schema.json, and writes the batch
// through public.backfill_message_contents (whole-content replace, user
// triggers off; see its schema file). Rows it cannot convert, or whose
// conversion the contract refuses, are reported and left as they are.
//
// RUNBOOK (production)
//   1. Deploy the migration that adds backfill_message_contents.
//   2. Dry run, and read the report (counts per kind, every refused id):
//        SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… \
//        deno run -A _scripts/backfill_messages_v1.ts --dry-run
//   3. Decide what to do with the refused rows (they are what keeps the
//      constraint from validating): extend messages_v0.ts with a new case
//      and its fixture, or delete them.
//   4. Run it for real (same command without --dry-run). Idempotent: it only
//      writes rows still without content.version; rerun until it reports 0.
//   5. Then, in a new migration: `alter table public.messages validate
//      constraint messages_content_schema;` and the schema file without
//      `not valid`; drop backfill_message_contents.
//   6. Then in the UI: remove src/supabase/messages-v0.ts and the toV1 call
//      in chatSlice.pushMessages.
// Steps 5 and 6 are not in this change: they only hold once 4 has run.
import type { SupabaseClient } from "@supabase/supabase-js";
import Ajv from "npm:ajv@8.17.1";
import { toV1Content } from "../_shared/messages_v0.ts";
import { SCHEMA_PATH } from "../_shared/contracts/generate.ts";

export type BackfillReport = {
  dryRun: boolean;
  scanned: number;
  converted: number;
  written: number;
  byKind: Record<string, number>;
  refused: { id: string; reason: string }[];
};

// deno-lint-ignore no-explicit-any
type Client = SupabaseClient<any>;

export async function backfillMessagesV1(
  client: Client,
  { batchSize = 1000, dryRun = false }: {
    batchSize?: number;
    dryRun?: boolean;
  } = {},
): Promise<BackfillReport> {
  // deno-lint-ignore no-explicit-any
  const ajv = new (Ajv as any)({ strict: false, allErrors: false });
  const validate = ajv.compile(
    JSON.parse(await Deno.readTextFile(SCHEMA_PATH)),
  );

  const report: BackfillReport = {
    dryRun,
    scanned: 0,
    converted: 0,
    written: 0,
    byKind: {},
    refused: [],
  };

  // Keyset over the primary key: the whole pass reads the table once, however
  // few of its rows are v0.
  let after = "00000000-0000-0000-0000-000000000000";

  while (true) {
    const { data: rows } = await client
      .from("messages")
      .select("id, content")
      .gt("id", after)
      .is("content->>version", null)
      .neq("content", "{}")
      .order("id")
      .limit(batchSize)
      .throwOnError();

    if (!rows.length) break;
    after = rows.at(-1)!.id;
    report.scanned += rows.length;

    const writes: { id: string; content: unknown }[] = [];

    for (const row of rows as { id: string; content: unknown }[]) {
      const result = toV1Content(row.content);

      if (!result.ok) {
        report.refused.push({ id: row.id, reason: result.reason });
        continue;
      }

      if (!validate(result.content)) {
        report.refused.push({
          id: row.id,
          reason: `refused by the v1 contract: ${
            ajv.errorsText(validate.errors)
          }`,
        });
        continue;
      }

      report.converted++;
      const kind = String(result.content.kind);
      report.byKind[kind] = (report.byKind[kind] ?? 0) + 1;
      writes.push({ id: row.id, content: result.content });
    }

    // The writer takes at most 1,000 rows a call (its lock is per call).
    for (let i = 0; !dryRun && i < writes.length; i += 1000) {
      const { data: count } = await client
        .rpc("backfill_message_contents", { _rows: writes.slice(i, i + 1000) })
        .throwOnError();
      report.written += count as number;
    }

    if (rows.length < batchSize) break;
  }

  return report;
}

if (import.meta.main) {
  const { createClient } = await import("@supabase/supabase-js");
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    console.error("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required");
    Deno.exit(2);
  }
  const batch = Deno.args.find((a) => a.startsWith("--batch="));
  const report = await backfillMessagesV1(
    createClient(url, key, { auth: { persistSession: false } }),
    {
      dryRun: Deno.args.includes("--dry-run"),
      batchSize: batch ? Number(batch.split("=")[1]) : undefined,
    },
  );
  console.log(JSON.stringify(report, null, 2));
}
