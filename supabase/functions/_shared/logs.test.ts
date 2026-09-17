import { assertEquals } from "jsr:@std/assert@1";
import { insertLog, type LogInsert } from "./logs.ts";

// F05: a failed audit-log write must never abort the caller.

const row: LogInsert = {
  organization_id: "aaaaaaaa-0000-4000-8000-000000000001",
  category: "history",
  service: "whatsapp",
  level: "error",
  message: "test",
};

function fakeClient(
  outcome: { error: unknown } | (() => never),
) {
  return {
    from(_table: "logs") {
      return {
        insert(_row: LogInsert) {
          if (typeof outcome === "function") outcome();
          return Promise.resolve(outcome as { error: unknown });
        },
      };
    },
  };
}

Deno.test("insertLog: a PostgREST error is swallowed and reported as false", async () => {
  const ok = await insertLog(
    fakeClient({ error: { code: "23503", message: "fk violation" } }),
    row,
  );
  assertEquals(ok, false);
});

Deno.test("insertLog: a thrown error (network) is swallowed too", async () => {
  const ok = await insertLog(
    fakeClient(() => {
      throw new Error("connection reset");
    }),
    row,
  );
  assertEquals(ok, false);
});

Deno.test("insertLog: success is true", async () => {
  assertEquals(await insertLog(fakeClient({ error: null }), row), true);
});
