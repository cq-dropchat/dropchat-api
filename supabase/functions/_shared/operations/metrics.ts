/** Pure analysis of existing event logs: no payloads or IDs in metric labels. */
export type EventSample = {
  ts: string;
  event: string;
  outcome: string;
  provider?: string;
  duration_ms?: number;
};
export function distributions(
  samples: EventSample[],
  start: string,
  end: string,
) {
  const allowed = new Set([
    "queue.started",
    "client.initial",
    "client.history",
    "client.recovery",
    "client.visible",
    "persist.completed",
    "webhook.persisted",
    "agent.completed",
    "media.completed",
    "dispatch.completed",
    "provider.accepted",
    "provider.rejected",
  ]);
  const grouped = new Map<string, number[]>();
  for (const sample of samples) {
    if (
      !allowed.has(sample.event) || sample.ts < start || sample.ts >= end ||
      !Number.isFinite(sample.duration_ms) || sample.duration_ms! < 0
    ) continue;
    const provider =
      ["whatsapp", "instagram", "slack", "local", "google"].includes(
          sample.provider ?? "",
        )
        ? sample.provider
        : "internal";
    const outcome =
      ["success", "failure", "started", "accepted", "delivered", "skipped"]
          .includes(
            sample.outcome,
          )
        ? sample.outcome
        : "unknown";
    const key = `${sample.event}:${provider}:${outcome}`;
    const values = grouped.get(key) ?? [];
    values.push(sample.duration_ms!);
    grouped.set(key, values);
  }
  return [...grouped].map(([stage, values]) => {
    values.sort((a, b) => a - b);
    const percentile = (p: number) =>
      values[Math.max(0, Math.ceil(values.length * p) - 1)];
    return {
      stage,
      start,
      end,
      samples: values.length,
      p50_ms: percentile(.5),
      p95_ms: percentile(.95),
      p99_ms: percentile(.99),
    };
  });
}
export type HealthSample = {
  observed_at: string;
  overdue: number;
  oldest_due_age_s: number;
  last_worker_start_at: string | null;
  cron_failures: number;
  expired_leases: number;
  business_failures: number;
  business_total: number;
  complete_business_window: boolean;
  dead_letters?: number;
};
export type AlertEvent = {
  key: string;
  state: "firing" | "recovered";
  runbook: string;
  observed_at: string;
};
export function alertEvaluator() {
  const active = new Set<string>();
  let overdueStreak = 0;
  let previous = 0;
  let leaseStreak = 0;
  let stalledSince: number | null = null;
  return (sample: HealthSample): AlertEvent[] => {
    const now = Date.parse(sample.observed_at);
    if (
      !Number.isFinite(now) || now <= previous ||
      (previous && now - previous < 50_000)
    ) return [];
    if (
      ![
        sample.overdue,
        sample.oldest_due_age_s,
        sample.cron_failures,
        sample.expired_leases,
        sample.business_failures,
        sample.business_total,
      ].every((value) => Number.isFinite(value) && value >= 0)
    ) return [];
    // Only consecutive minute samples count; a collection gap resets evidence.
    overdueStreak = sample.oldest_due_age_s > 60
      ? (previous && now - previous <= 90_000 ? overdueStreak + 1 : 1)
      : 0;
    if (previous && now - previous > 90_000) stalledSince = null;
    leaseStreak = sample.expired_leases > 0
      ? (previous && now - previous <= 90_000 ? leaseStreak + 1 : 1)
      : 0;
    if (sample.overdue > 0) stalledSince ??= now;
    else stalledSince = null;
    const parsedWorker = Date.parse(sample.last_worker_start_at ?? "");
    const verifiedWorker = Number.isFinite(parsedWorker) && parsedWorker <= now
      ? parsedWorker
      : null;
    const worker = verifiedWorker ?? stalledSince ?? now;
    const conditions: Record<string, boolean> = {
      overdue: sample.oldest_due_age_s > 60 &&
        (overdueStreak >= 3 || active.has("overdue")),
      stalled: sample.overdue > 0 &&
        (now - Math.max(worker, stalledSince ?? now) >= 300_000 ||
          (active.has("stalled") &&
            (verifiedWorker === null || now - verifiedWorker >= 300_000))),
      business: sample.complete_business_window
        ? (sample.business_failures >= 5 && sample.business_total > 0 &&
          sample.business_failures / sample.business_total > .01)
        : active.has("business"),
      cron: sample.cron_failures > 0,
      leases: sample.expired_leases > 0 &&
        (leaseStreak >= 2 || active.has("leases")),
    };
    previous = now;
    const changes: AlertEvent[] = [];
    for (const [key, firing] of Object.entries(conditions)) {
      if (firing && !active.has(key)) {
        active.add(key);
        changes.push({
          key,
          state: "firing",
          runbook: `OPERATIONS.md#alerta-${key}`,
          observed_at: sample.observed_at,
        });
      } else if (!firing && active.delete(key)) {
        changes.push({
          key,
          state: "recovered",
          runbook: `OPERATIONS.md#alerta-${key}`,
          observed_at: sample.observed_at,
        });
      }
    }
    return changes;
  };
}
