import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { normalizeHealth, type RawHealth } from "./health.ts";
const raw: RawHealth = {
  observed_at: "2026-10-09T00:10:00Z",
  transport: [{
    overdue: 2,
    oldest_due_age_s: 70,
    expired_leases: 1,
    dead_letters: 2,
  }],
  receipts: {
    overdue: 1,
    oldest_due_age_s: 80,
    expired_leases: 2,
    dead_letters: 1,
  },
  cron_failures: [{}],
};
Deno.test("SQL receipt and transport evidence combine without inferring business completion", () => {
  const result = normalizeHealth(raw, [{
    ts: "2026-10-09T00:09:00Z",
    event: "queue.started",
    outcome: "started",
  }, {
    ts: "2026-10-09T00:11:00Z",
    event: "agent.started",
    outcome: "started",
  }]);
  assertEquals([
    result.overdue,
    result.oldest_due_age_s,
    result.expired_leases,
    result.cron_failures,
    result.last_worker_start_at,
    result.complete_business_window,
  ], [3, 80, 3, 1, "2026-10-09T00:09:00.000Z", false]);
  assertThrows(() =>
    normalizeHealth({ ...raw, receipts: undefined } as unknown as RawHealth, [])
  );
});
Deno.test("business denominator requires a complete unsampled ten-minute window", () => {
  const business_window = {
    start: "2026-10-09T00:00:00Z",
    end: raw.observed_at,
    failures: 5,
    total: 100,
    complete: true,
    sampled: false,
    cancellations_excluded: true,
  };
  assertEquals(
    normalizeHealth({ ...raw, business_window }, []).complete_business_window,
    true,
  );
  for (
    const patch of [{ sampled: true }, { cancellations_excluded: false }, {
      start: "2026-10-09T00:01:00Z",
    }, { failures: 101 }]
  ) {
    assertEquals(
      normalizeHealth({
        ...raw,
        business_window: { ...business_window, ...patch },
      }, []).complete_business_window,
      false,
    );
  }
});
