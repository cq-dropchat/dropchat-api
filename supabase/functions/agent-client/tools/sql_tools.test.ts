// F29 (step 3) — characterization of the SQL tools, written before splitting
// tools/sql.ts (1,337 lines) into a module per driver and one for schema
// introspection.
//
// Runs the five tools with the postgres driver against the local Supabase
// database (a scratch schema, dropped afterwards) and snapshots what each
// returns, plus the tool definitions the model sees. The mysql and libsql
// drivers have no local server here: the split moves them verbatim.
//
// Recorded first with two of the tools failing on postgres; the snapshot
// changed once, with the fix that made getDbSchema and bulkInsert work
// there (see sql.test.ts).
//
// Regenerate only for an intended change:
//   deno test -A agent-client/tools/sql_tools.test.ts -- --update
import "../../_shared/testing/env.ts";
import { assertEquals } from "jsr:@std/assert@1";
import { assertSnapshot } from "jsr:@std/testing@1/snapshot";
import { createClient } from "@supabase/supabase-js";
import { env, fixture } from "../../_shared/testing/env.ts";
import { downloadFromStorage, uploadToStorage } from "../../_shared/media.ts";
import type { RequestContext } from "../protocols/base.ts";
import {
  bulkInsertImplementation,
  executeSqlImplementation,
  getDbSchemaImplementation,
  sampleTableRowsImplementation,
  selectAsCsvImplementation,
  SQLTools,
} from "./sql.ts";

async function localDbUp() {
  try {
    const conn = await Deno.connect({ hostname: "127.0.0.1", port: 54322 });
    conn.close();
    return true;
  } catch {
    return false;
  }
}

const CONFIG = {
  driver: "postgres" as const,
  host: "127.0.0.1",
  port: 54322,
  user: "postgres",
  password: "postgres", // the local Supabase default
  database: "postgres",
};

const context = {
  organization: { id: fixture.orgA },
} as unknown as RequestContext;

/** The result, or the message it failed with. */
async function outcome<T>(run: () => Promise<T>) {
  try {
    return { result: await run() };
  } catch (error) {
    return { error: (error as Error).message };
  }
}

const SETUP = `
  drop schema if exists f29_sql cascade;
  create schema f29_sql;
  create type f29_sql.plan as enum ('free', 'pro');
  create table f29_sql.customers (
    id integer primary key,
    email text not null unique,
    plan f29_sql.plan not null default 'free',
    note text
  );
  comment on table f29_sql.customers is 'People who pay';
  comment on column f29_sql.customers.email is 'Login email';
  create table f29_sql.orders (
    id integer primary key,
    customer_id integer not null references f29_sql.customers (id),
    total numeric(10, 2) not null,
    unique (customer_id, id)
  );
  insert into f29_sql.customers values
    (1, 'ana@example.test', 'pro', null),
    (2, 'beto@example.test', 'free', 'vip'),
    (3, 'caro@example.test', 'free', null);
  insert into f29_sql.orders values (10, 1, 99.50), (11, 1, 5.00), (12, 2, 20.00);
`;

Deno.test({
  name: "F29: SQL tools with the postgres driver (characterization)",
  ignore: !(await localDbUp()),
  sanitizeResources: false,
  sanitizeOps: false,
  async fn(t) {
    Deno.env.set("AGENT_TOOL_ALLOWED_HOSTS", "127.0.0.1");
    const supabase = createClient(env.url, env.serviceRoleKey, {
      auth: { persistSession: false },
    });
    const uploaded: string[] = [];

    try {
      await executeSqlImplementation({ query: SETUP }, CONFIG, context);

      await t.step("definitions", async (t) => {
        await assertSnapshot(
          t,
          SQLTools.map((
            { name, type, description, inputSchema, outputSchema },
          ) => ({
            name,
            type,
            description,
            inputSchema,
            outputSchema,
          })),
        );
      });

      await t.step("getDbSchema", async (t) => {
        await assertSnapshot(
          t,
          await outcome(() =>
            getDbSchemaImplementation({ schemas: ["f29_sql"] }, CONFIG, context)
          ),
        );
      });

      await t.step("sampleTableRows", async (t) => {
        await assertSnapshot(
          t,
          await sampleTableRowsImplementation(
            { schemas: ["f29_sql"], limit: 2 },
            CONFIG,
            context,
          ),
        );
      });

      await t.step("executeSql", async (t) => {
        await assertSnapshot(
          t,
          await executeSqlImplementation(
            {
              query:
                "select c.email, sum(o.total) as total from f29_sql.customers c join f29_sql.orders o on o.customer_id = c.id group by c.email order by c.email",
            },
            CONFIG,
            context,
          ),
        );
      });

      await t.step("selectAsCsv", async (t) => {
        const result = await selectAsCsvImplementation(
          {
            query: "select id, email, note from f29_sql.customers order by id",
            file_name: "customers.csv",
          },
          CONFIG,
          context,
          supabase,
        );
        if (result.file_uri) uploaded.push(result.file_uri);
        const csv = result.file_uri
          ? await (await downloadFromStorage(supabase, result.file_uri)).text()
          : null;
        await assertSnapshot(t, { result, csv });

        const empty = await selectAsCsvImplementation(
          { query: "select 1 where false", file_name: "none.csv" },
          CONFIG,
          context,
          supabase,
        );
        assertEquals(empty, { file_uri: null, columns: [], rows_selected: 0 });
      });

      await t.step("bulkInsert", async (t) => {
        const uri = await uploadToStorage(
          supabase,
          fixture.orgA,
          new Blob(
            [
              "Customer Email,Amount,Ignored\nana@example.test,10.5,x\nbeto@example.test,,y\n",
            ],
            { type: "text/csv" },
          ),
          "import.csv",
        );
        uploaded.push(uri);

        const insert = await outcome(() =>
          bulkInsertImplementation(
            {
              schema: "f29_sql",
              table: "imported",
              columns: ["Customer Email", "Amount"],
              types: ["text", "numeric"],
              renames: [{ from: "Customer Email", to: "email" }],
              file_uri: uri,
            },
            CONFIG,
            context,
            supabase,
          )
        );
        const rows = await outcome(() =>
          executeSqlImplementation(
            { query: "select * from f29_sql.imported order by email" },
            CONFIG,
            context,
          )
        );
        await assertSnapshot(t, { insert, rows });
      });
    } finally {
      await executeSqlImplementation(
        { query: "drop schema if exists f29_sql cascade" },
        CONFIG,
        context,
      ).catch(() => {});
      await supabase.storage.from("media").remove(
        uploaded.map((u) => u.replace("internal://media/", "")),
      );
      Deno.env.delete("AGENT_TOOL_ALLOWED_HOSTS");
    }
  },
});
