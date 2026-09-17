// F08 — the SQL tool connected to any host/port an admin typed, with no
// connect or statement timeout: `host: "db.supabase.internal"` reached the
// project's own database from inside its network, and a `pg_sleep` held the
// Edge Function until the platform killed it.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import "../../_shared/testing/env.ts";
import { createClient } from "@supabase/supabase-js";
import { env, fixture } from "../../_shared/testing/env.ts";
import { uploadToStorage } from "../../_shared/media.ts";
import {
  bulkInsertImplementation,
  executeSqlImplementation,
  getDbSchemaImplementation,
} from "./sql.ts";
import type { RequestContext } from "../protocols/base.ts";
import { DestinationError } from "../../_shared/net_guard.ts";

const context = {} as RequestContext;

async function localDbUp() {
  try {
    const conn = await Deno.connect({ hostname: "127.0.0.1", port: 54322 });
    conn.close();
    return true;
  } catch {
    return false;
  }
}

Deno.test("F08: the SQL tool refuses internal hosts before connecting", async () => {
  for (
    const host of [
      "db.supabase.internal",
      "localhost",
      "127.0.0.1",
      "10.0.0.5",
      "169.254.169.254",
      "db",
    ]
  ) {
    await assertRejects(
      () =>
        executeSqlImplementation(
          { query: "select 1" },
          { driver: "postgres", host, port: 5432, user: "postgres" },
          context,
        ),
      DestinationError,
      undefined,
      host,
    );
  }
});

Deno.test("F08: the libsql driver refuses internal URLs too", async () => {
  await assertRejects(
    () =>
      executeSqlImplementation(
        { query: "select 1" },
        { driver: "libsql", url: "http://127.0.0.1:8080" },
        context,
      ),
    DestinationError,
  );
});

Deno.test({
  name: "F08: a long statement is cut by statement_timeout",
  ignore: !(await localDbUp()),
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    Deno.env.set("AGENT_TOOL_ALLOWED_HOSTS", "127.0.0.1");
    try {
      const t0 = performance.now();
      await assertRejects(() =>
        executeSqlImplementation(
          { query: "select pg_sleep(10)" },
          {
            driver: "postgres",
            host: "127.0.0.1",
            port: 54322,
            user: "postgres",
            password: "postgres",
            database: "postgres",
          },
          context,
        )
      );
      const ms = performance.now() - t0;
      assert(ms < 8000, `statement ran ${ms.toFixed(0)} ms`);
    } finally {
      Deno.env.delete("AGENT_TOOL_ALLOWED_HOSTS");
    }
  },
});

// ---------------------------------------------------------------------------
// Found by F29's characterization of the SQL tools: two of them never worked
// with the postgres driver. getDbSchema aliased a column with MySQL's
// backticks (`default`), a syntax error in Postgres; bulkInsert bound values
// to `?` placeholders, which Postgres does not accept ($1, $2, …).
// ---------------------------------------------------------------------------

const LOCAL_PG = {
  driver: "postgres" as const,
  host: "127.0.0.1",
  port: 54322,
  user: "postgres",
  password: "postgres", // the local Supabase default
  database: "postgres",
};

Deno.test({
  name: "getDbSchema describes a postgres schema",
  ignore: !(await localDbUp()),
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    Deno.env.set("AGENT_TOOL_ALLOWED_HOSTS", "127.0.0.1");
    try {
      await executeSqlImplementation(
        {
          query: `drop schema if exists sqlfix cascade;
          create schema sqlfix;
          create table sqlfix.t (id integer primary key, label text default 'x');
          comment on table sqlfix.t is 'the table';
          comment on column sqlfix.t.label is 'the label';
          create table sqlfix.parent (a integer, b integer, primary key (a, b));
          create table sqlfix.child (
            id integer primary key,
            pa integer, pb integer,
            unique (pb, pa),
            foreign key (pa, pb) references sqlfix.parent (a, b)
          );`,
        },
        LOCAL_PG,
        context,
      );

      const schema = await getDbSchemaImplementation(
        { schemas: ["sqlfix"] },
        LOCAL_PG,
        context,
      );
      const table = schema.tables.find((t) => t.name === "t");
      assert(table, JSON.stringify(schema));
      assertEquals(table.columns.map((c) => c.name), ["id", "label"]);
      assertEquals(table.columns[1].default, "'x'::text");

      // A column's comment is not the table's.
      assertEquals(table.comment, "the table");
      assertEquals(table.columns[1].comment, "the label");

      // Multi-column constraints list each column once, in key order, and a
      // composite foreign key pairs each column with the one it references.
      const child = schema.tables.find((t) => t.name === "child")!;
      const unique = child.constraints.find((c) => c.type === "UNIQUE")!;
      assertEquals(unique.columns, ["pb", "pa"]);
      const fk = child.constraints.find((c) => c.type === "FOREIGN KEY")!;
      assertEquals(fk.columns, ["pa", "pb"]);
      assert(fk.type === "FOREIGN KEY");
      assertEquals(fk.referenced_table, {
        schema: "sqlfix",
        name: "parent",
        columns: ["a", "b"],
      });
      const parent = schema.tables.find((t) => t.name === "parent")!;
      assertEquals(parent.constraints[0].columns, ["a", "b"]);
    } finally {
      await executeSqlImplementation(
        { query: "drop schema if exists sqlfix cascade" },
        LOCAL_PG,
        context,
      ).catch(() => {});
      Deno.env.delete("AGENT_TOOL_ALLOWED_HOSTS");
    }
  },
});

Deno.test({
  name: "bulkInsert loads a CSV into postgres",
  ignore: !(await localDbUp()),
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    Deno.env.set("AGENT_TOOL_ALLOWED_HOSTS", "127.0.0.1");
    const supabase = createClient(env.url, env.serviceRoleKey, {
      auth: { persistSession: false },
    });
    const uri = await uploadToStorage(
      supabase,
      fixture.orgA,
      new Blob(["name,amount\nana,1.5\nbeto,\n"], { type: "text/csv" }),
      "sqlfix.csv",
    );
    try {
      await executeSqlImplementation(
        {
          query: "drop schema if exists sqlfix cascade; create schema sqlfix;",
        },
        LOCAL_PG,
        context,
      );

      const result = await bulkInsertImplementation(
        {
          schema: "sqlfix",
          table: "imported",
          types: ["text", "numeric"],
          file_uri: uri,
        },
        LOCAL_PG,
        context,
        supabase,
      );
      assertEquals(result, { columns: ["name", "amount"], rows_inserted: 2 });

      const rows = await executeSqlImplementation(
        {
          query: "select name, amount::text from sqlfix.imported order by name",
        },
        LOCAL_PG,
        context,
      );
      assertEquals([...rows], [
        { name: "ana", amount: "1.5" },
        { name: "beto", amount: null },
      ]);
    } finally {
      await executeSqlImplementation(
        { query: "drop schema if exists sqlfix cascade" },
        LOCAL_PG,
        context,
      ).catch(() => {});
      await supabase.storage.from("media").remove([
        uri.replace("internal://media/", ""),
      ]);
      Deno.env.delete("AGENT_TOOL_ALLOWED_HOSTS");
    }
  },
});
