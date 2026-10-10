// Disposable local export profile; generation is outside measurement.
import "../../functions/_shared/testing/env.ts";
import postgres from "postgres";
import { createClient } from "@supabase/supabase-js";
import { Unzip, UnzipInflate } from "fflate";
import { streamOrganizationExport } from "../../functions/org-export/export.ts";
import type { Database } from "../../functions/_shared/types/database_types.ts";
import { edgeRuntimeIsUp, env } from "../../functions/_shared/testing/env.ts";
if (
  !/^http:\/\/(127\.0\.0\.1|localhost):54321$/.test(env.url) ||
  !Deno.env.get("SUPABASE_DB_URL")?.includes("127.0.0.1:54322")
) throw new Error("Local stack only");
if (await edgeRuntimeIsUp()) throw new Error("Exclude edge-runtime");
const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
  max: 2,
  onnotice: () => {},
});
const org = "e5000000-0000-4000-8000-000000000001",
  conv = "e5000000-0000-4000-8000-0000000000c1";
const client = createClient<Database>(env.url, env.serviceRoleKey, {
  auth: { persistSession: false },
});
await Deno.mkdir("artifacts/export", { recursive: true });
try {
  await sql`insert into public.organizations(id,name) values (${org},'export-capacity') on conflict do nothing`;
  await sql`insert into public.organizations_addresses(organization_id,service,address) values (${org},'whatsapp','export-capacity') on conflict do nothing`;
  await sql`insert into public.conversations(id,organization_id,service,organization_address,address) values (${conv},${org},'whatsapp','export-capacity','peer') on conflict do nothing`;
  for (const volume of [100_000, 1_000_000]) {
    for (const payloadBytes of [64, 1024]) {
      // Bulk fixture generation is not advertised as write throughput: replica
      // skips triggers ONLY in this generation transaction; all benchmark reads
      // and the concurrent writer below use ordinary connections/real triggers.
      await sql.begin(async (tx) => {
        const t = tx as unknown as typeof sql;
        await t`set local session_replication_role=replica`;
        await t`delete from public.messages where organization_id=${org}`;
        await t`insert into public.messages(id,organization_id,conversation_id,service,organization_address,conversation_address,sender_address,external_id,content,timestamp)
    select ('e5000000-0000-4000-8001-'||lpad(n::text,12,'0'))::uuid,${org}::uuid,${conv}::uuid,'whatsapp','export-capacity','peer','peer','export-'||n,
    jsonb_build_object('version','1','type','text','kind','text','text',repeat('x',${payloadBytes})),now()-interval '1 day' from generate_series(1,${volume}) n`;
      });
      const canceled = streamOrganizationExport(client, org);
      const reader = canceled.stream.getReader();
      while (!canceled.counts.messages) {
        await reader.read();
      }
      const cancelAt = performance.now();
      await reader.cancel();
      const started = performance.now();
      let peak = Deno.memoryUsage().rss;
      let messageRows = 0;
      let fileCount = 0;
      let failure: unknown;
      const decoder = new TextDecoder();
      const unzip = new Unzip((file) => {
        fileCount++;
        let tail = "";
        file.ondata = (error, data, final) => {
          if (error) {
            failure = error;
            return;
          }
          if (file.name !== "messages.ndjson") return;
          tail += decoder.decode(data, { stream: !final });
          const lines = tail.split("\n");
          tail = lines.pop()!;
          for (const line of lines) {
            if (line) {
              const row = JSON.parse(line);
              if (row.organization_id !== org) {
                failure = new Error("Cross-tenant export row");
              }
              messageRows++;
            }
          }
          if (final && tail) failure = new Error("Truncated NDJSON");
        };
        file.start();
      });
      unzip.register(UnzipInflate);
      const sample = setInterval(() => {
        peak = Math.max(peak, Deno.memoryUsage().rss);
      }, 50);
      let writes = 0;
      const writer = (async () => {
        for (let i = 0; i < 10; i++) {
          await sql`insert into public.messages(organization_id,conversation_id,service,organization_address,conversation_address,sender_address,external_id,content)
     values (${org},${conv},'whatsapp','export-capacity','peer','peer',${`concurrent-${i}`},'{"version":"1","type":"text","kind":"text","text":"concurrent"}')`;
          writes++;
          await new Promise((r) => setTimeout(r, 100));
        }
      })();
      const exported = streamOrganizationExport(client, org);
      try {
        for await (const chunk of exported.stream) {
          unzip.push(chunk, false);
          if (failure) throw failure;
        }
        unzip.push(new Uint8Array(), true);
        if (failure) throw failure;
      } finally {
        clearInterval(sample);
        await writer;
      }
      if (
        messageRows < volume || messageRows > volume + 10 ||
        messageRows !== exported.counts.messages || fileCount !== 9
      ) {
        throw new Error(
          `ZIP mismatch ${messageRows} ${exported.counts.messages} ${fileCount}`,
        );
      }
      const report = {
        volume,
        payload_bytes: payloadBytes,
        exported_messages: messageRows,
        files: fileCount,
        zip_bytes: exported.bytes,
        duration_ms: performance.now() - started,
        peak_rss_bytes: peak,
        cancel_ms: started - cancelAt,
        cancel_messages: canceled.counts.messages,
        concurrent_writes: writes,
        qualification:
          "local service-role exporter; best-effort under concurrent writes; no Storage/runtime size limits validated",
      };
      await Deno.writeTextFile(
        `artifacts/export/${volume}-${payloadBytes}.json`,
        JSON.stringify(report, null, 2) + "\n",
      );
      console.log(JSON.stringify(report));
    }
  }
} finally {
  await sql.begin(async (tx) => {
    const t = tx as unknown as typeof sql;
    await t`set local session_replication_role=replica`;
    await t`delete from public.messages where organization_id=${org}`;
  });
  await sql.end();
}
