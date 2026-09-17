// F08 — the SQL tool connected to any host/port an admin typed, with no
// connect or statement timeout: `host: "db.supabase.internal"` reached the
// project's own database from inside its network, and a `pg_sleep` held the
// Edge Function until the platform killed it.
import { assert, assertRejects } from "jsr:@std/assert@1";
import { executeSqlImplementation } from "./sql.ts";
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
