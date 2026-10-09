/** SQL snapshot + existing worker logs. Missing evidence never means recovery. */
import type { EventSample, HealthSample } from "./metrics.ts";
type QueueState = {
  overdue: number;
  oldest_due_age_s: number | null;
  expired_leases: number;
  dead_letters: number;
};
export type RawHealth = {
  observed_at: string;
  transport: QueueState[];
  receipts: QueueState;
  cron_failures: unknown[];
  business_window?: {
    start: string;
    end: string;
    failures: number;
    total: number;
    complete: boolean;
    sampled: boolean;
    cancellations_excluded: boolean;
  };
};
export function normalizeHealth(
  raw: RawHealth,
  events: EventSample[],
): HealthSample {
  const now = Date.parse(raw.observed_at);
  if (
    !Number.isFinite(now) || !Array.isArray(raw.transport) || !raw.receipts ||
    !Array.isArray(raw.cron_failures)
  ) throw new Error("Incomplete health snapshot");
  const queues = [...raw.transport, raw.receipts];
  for (const q of queues) {
    if (
      ![q.overdue, q.expired_leases, q.dead_letters, q.oldest_due_age_s ?? 0]
        .every((n) => Number.isFinite(n) && n >= 0)
    ) throw new Error("Invalid queue health");
  }
  const starts = events.filter((e) =>
    ["queue.started", "agent.started", "media.started", "dispatch.started"]
      .includes(e.event) &&
    e.outcome === "started" && Number.isFinite(Date.parse(e.ts)) &&
    Date.parse(e.ts) <= now
  ).map((e) => Date.parse(e.ts));
  const b = raw.business_window;
  const complete = !!b && b.complete && !b.sampled &&
    b.cancellations_excluded && Date.parse(b.end) === now &&
    now - Date.parse(b.start) === 600000 &&
    [b.failures, b.total].every((n) => Number.isInteger(n) && n >= 0) &&
    b.failures <= b.total;
  return {
    observed_at: new Date(now).toISOString(),
    overdue: queues.reduce((n, q) => n + q.overdue, 0),
    oldest_due_age_s: Math.max(
      0,
      ...queues.map((q) => q.oldest_due_age_s ?? 0),
    ),
    dead_letters: queues.reduce((n, q) => n + q.dead_letters, 0),
    expired_leases: queues.reduce((n, q) => n + q.expired_leases, 0),
    cron_failures: raw.cron_failures.length,
    last_worker_start_at: starts.length
      ? new Date(Math.max(...starts)).toISOString()
      : null,
    business_failures: complete ? b!.failures : 0,
    business_total: complete ? b!.total : 0,
    complete_business_window: complete,
  };
}
