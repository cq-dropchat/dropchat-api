import { assertEquals } from "jsr:@std/assert@1";
import { alertEvaluator, distributions, type HealthSample } from "./metrics.ts";
Deno.test("metrics include period/sample volume and use quantiles, not SQL averages", () => {
  const rows = Array.from(
    { length: 100 },
    (_, i) => ({
      ts: "2026-10-08T00:00:00Z",
      event: "client.history",
      outcome: "success",
      duration_ms: i + 1,
      provider: "arbitrary-secret-label",
    }),
  );
  assertEquals(distributions(rows, "2026-10-08", "2026-10-09"), [{
    stage: "client.history:internal:success",
    start: "2026-10-08",
    end: "2026-10-09",
    samples: 100,
    p50_ms: 50,
    p95_ms: 95,
    p99_ms: 99,
  }]);
});
Deno.test("alerts require consecutive evidence, deduplicate and signal recovery", () => {
  const evaluate = alertEvaluator();
  const sample = (minute: number, age = 61): HealthSample => ({
    observed_at: new Date(Date.UTC(2026, 9, 8, 0, minute)).toISOString(),
    overdue: 1,
    oldest_due_age_s: age,
    last_worker_start_at: null,
    cron_failures: 0,
    expired_leases: 0,
    business_failures: 0,
    business_total: 100,
    complete_business_window: true,
  });
  assertEquals(evaluate(sample(0)), []);
  assertEquals(evaluate(sample(1)), []);
  assertEquals(evaluate(sample(2)).map((e) => [e.key, e.state]), [[
    "overdue",
    "firing",
  ]]);
  assertEquals(evaluate(sample(3)), []);
  assertEquals(
    evaluate({ ...sample(4, 0), overdue: 0 }).map((e) => [e.key, e.state]),
    [["overdue", "recovered"]],
  );
});
Deno.test("sampled business events cannot masquerade as a complete error window", () => {
  const evaluate = alertEvaluator();
  const sample: HealthSample = {
    observed_at: "2026-10-08T00:00:00Z",
    overdue: 0,
    oldest_due_age_s: 0,
    last_worker_start_at: null,
    cron_failures: 0,
    expired_leases: 0,
    business_failures: 5,
    business_total: 10,
    complete_business_window: false,
  };
  assertEquals(evaluate(sample), []);
  assertEquals(
    evaluate({
      ...sample,
      observed_at: "2026-10-08T00:01:00Z",
      complete_business_window: true,
    }).map((e) => e.key),
    ["business"],
  );
});

Deno.test("stalled workers, cron and repeated leases fire and recover independently", () => {
  const evaluate = alertEvaluator();
  const sample = (minute: number): HealthSample => ({
    observed_at: new Date(Date.UTC(2026, 9, 8, 0, minute)).toISOString(),
    overdue: 1,
    oldest_due_age_s: 0,
    last_worker_start_at: null,
    cron_failures: minute < 2 ? 1 : 0,
    expired_leases: minute < 3 ? 1 : 0,
    business_failures: 0,
    business_total: 0,
    complete_business_window: false,
  });
  assertEquals(evaluate(sample(0)).map((e) => [e.key, e.state]), [[
    "cron",
    "firing",
  ]]);
  assertEquals(evaluate(sample(1)).map((e) => [e.key, e.state]), [[
    "leases",
    "firing",
  ]]);
  assertEquals(evaluate(sample(2)).map((e) => [e.key, e.state]), [[
    "cron",
    "recovered",
  ]]);
  assertEquals(evaluate(sample(3)).map((e) => [e.key, e.state]), [[
    "leases",
    "recovered",
  ]]);
  assertEquals(evaluate(sample(4)), []);
  assertEquals(evaluate(sample(5)).map((e) => [e.key, e.state]), [[
    "stalled",
    "firing",
  ]]);
  assertEquals(
    evaluate({ ...sample(6), last_worker_start_at: sample(6).observed_at }).map(
      (e) => [e.key, e.state],
    ),
    [["stalled", "recovered"]],
  );
});
Deno.test("collection gaps and invalid timestamps cannot invent sustained overdue evidence", () => {
  const evaluate = alertEvaluator();
  const base: HealthSample = {
    observed_at: "2026-10-08T00:00:00Z",
    overdue: 1,
    oldest_due_age_s: 90,
    last_worker_start_at: null,
    cron_failures: 0,
    expired_leases: 1,
    business_failures: 0,
    business_total: 0,
    complete_business_window: false,
  };
  assertEquals(evaluate(base), []);
  assertEquals(evaluate({ ...base, observed_at: "invalid" }), []);
  assertEquals(evaluate({ ...base, observed_at: "2026-10-08T00:10:00Z" }), []);
  assertEquals(
    distributions(
      [{
        ts: base.observed_at,
        event: "secret",
        outcome: "failure",
        duration_ms: 99,
      }, {
        ts: base.observed_at,
        event: "client.history",
        outcome: "success",
        duration_ms: -1,
      }],
      "2026-10-08",
      "2026-10-09",
    ),
    [],
  );
});

Deno.test("rapid polling does not invent three minutes of overdue work", () => {
  const evaluate = alertEvaluator();
  const base: HealthSample = {
    observed_at: "2026-10-08T00:00:00Z",
    overdue: 1,
    oldest_due_age_s: 61,
    last_worker_start_at: null,
    cron_failures: 0,
    expired_leases: 0,
    business_failures: 0,
    business_total: 0,
    complete_business_window: false,
  };
  assertEquals(evaluate(base), []);
  for (let second = 1; second < 10; second++) {
    assertEquals(
      evaluate({
        ...base,
        observed_at: new Date(Date.parse(base.observed_at) + second * 1000)
          .toISOString(),
      }),
      [],
    );
  }
});

Deno.test("collection gaps or an incomplete denominator do not announce false recovery", () => {
  const evaluate = alertEvaluator();
  const base: HealthSample = {
    observed_at: "2026-10-08T00:00:00Z",
    overdue: 1,
    oldest_due_age_s: 70,
    last_worker_start_at: null,
    cron_failures: 0,
    expired_leases: 1,
    business_failures: 5,
    business_total: 100,
    complete_business_window: true,
  };
  for (let minute = 0; minute < 6; minute++) {
    evaluate({
      ...base,
      observed_at: new Date(Date.parse(base.observed_at) + minute * 60000)
        .toISOString(),
    });
  }
  assertEquals(
    evaluate({
      ...base,
      observed_at: "2026-10-08T00:20:00Z",
      complete_business_window: false,
    }),
    [],
  );
  const recovered = evaluate({
    ...base,
    observed_at: "2026-10-08T00:21:00Z",
    overdue: 0,
    oldest_due_age_s: 0,
    expired_leases: 0,
    business_failures: 0,
  });
  assertEquals(recovered.map((e) => e.state), [
    "recovered",
    "recovered",
    "recovered",
    "recovered",
  ]);
});
