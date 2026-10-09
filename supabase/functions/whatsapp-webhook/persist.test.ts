import { assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database, MessageInsert } from "../_shared/supabase.ts";
import { newBatch } from "./batch.ts";
import { persistBatch } from "./persist.ts";
import type { OrgAddressMap } from "./org_addresses.ts";
Deno.test("statuses persist before slow media, downloads are bounded and failures retain rows", async () => {
  const batch = newBatch();
  batch.statuses = [{ external_id: "status" } as MessageInsert];
  batch.messages = Array.from(
    { length: 20 },
    (
      _,
      i,
    ) => ({
      organization_address: "wa",
      external_id: String(i),
      content: { version: "1", type: "text", kind: "text", text: String(i) },
    } as MessageInsert),
  );
  const written: MessageInsert[][] = [];
  const client = {
    from: () => ({
      upsert: (rows: MessageInsert[]) => {
        written.push(rows);
        const result = Promise.resolve({ error: null, data: [] });
        return Object.assign(result, { select: () => result });
      },
    }),
  } as unknown as SupabaseClient<Database>;
  let active = 0, peak = 0;
  await persistBatch(
    client,
    new Map([["wa", {
      organization_id: "org",
      extra: {},
    }]]) as unknown as OrgAddressMap,
    batch,
    async ({ message }) => {
      assertEquals(written[0], batch.statuses);
      active++;
      peak = Math.max(peak, active);
      await new Promise((resolve) => setTimeout(resolve, 1));
      active--;
      if (message.external_id === "3") throw new Error("download failed");
      return message;
    },
  );
  assertEquals(peak, 4);
  assertEquals(written[1].length, 20);
  assertEquals(written[1][3].status, { error: "download failed" });
  assertEquals(
    written[1].map((m) => m.external_id),
    batch.messages.map((m) => m.external_id),
  );
});
