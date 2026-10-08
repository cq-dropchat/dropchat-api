import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { mapConcurrent } from "./concurrency.ts";
Deno.test("media workers bound concurrency and preserve order across 100 items", async () => {
  let active = 0, peak = 0;
  const results = await mapConcurrent(
    Array.from({ length: 100 }, (_, i) => i),
    4,
    async (n) => {
      active++;
      peak = Math.max(peak, active);
      await new Promise((resolve) => setTimeout(resolve, n % 3));
      active--;
      return n * 2;
    },
  );
  assertEquals(peak, 4);
  assertEquals(results, Array.from({ length: 100 }, (_, i) => i * 2));
});
Deno.test("worker limits reject invalid configuration and empty input completes", async () => {
  assertEquals(await mapConcurrent([], 4, (n) => Promise.resolve(n)), []);
  await assertRejects(
    () => mapConcurrent([1], 0, (n) => Promise.resolve(n)),
    RangeError,
  );
});
