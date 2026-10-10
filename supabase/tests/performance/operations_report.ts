// Offline dashboard from existing allowlisted logs. No synchronous collection.
import {
  alertEvaluator,
  distributions,
  type EventSample,
  type HealthSample,
} from "../../functions/_shared/operations/metrics.ts";
import {
  normalizeHealth,
  type RawHealth,
} from "../../functions/_shared/operations/health.ts";
const [eventsPath, healthPath, start, end, output] = Deno.args;
if (
  !output || !Number.isFinite(Date.parse(start)) ||
  !Number.isFinite(Date.parse(end)) || Date.parse(start) >= Date.parse(end)
) {
  throw new Error(
    "usage: operations_report.ts events.jsonl health.jsonl startUTC endUTC output.json",
  );
}
const lines = async (path: string) =>
  (await Deno.readTextFile(path)).split("\n").filter(Boolean).map((line) =>
    JSON.parse(line)
  );
const events = await lines(eventsPath) as EventSample[];
const evaluate = alertEvaluator();
const health = (await lines(healthPath)).map((raw: RawHealth | HealthSample) =>
  "transport" in raw ? normalizeHealth(raw, events) : raw
);
const alerts = health.sort((a, b) => a.observed_at.localeCompare(b.observed_at))
  .flatMap(evaluate);
const metrics = distributions(
  events,
  new Date(start).toISOString(),
  new Date(end).toISOString(),
);
await Deno.writeTextFile(
  output,
  JSON.stringify(
    {
      start,
      end,
      metrics,
      health,
      alerts,
      qualification:
        "sampled durations; business denominator must be declared complete separately",
    },
    null,
    2,
  ) + "\n",
);
const escape = (value: string) =>
  value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(
    '"',
    "&quot;",
  );
const rows = metrics.map((m) =>
  `<tr><td>${escape(m.stage)}</td><td>${m.samples}</td><td>${
    m.p50_ms.toFixed(2)
  }</td><td>${m.p95_ms.toFixed(2)}</td><td>${m.p99_ms.toFixed(2)}</td></tr>`
).join("");
const healthRows = health.map((h) =>
  `<tr><td>${
    escape(h.observed_at)
  }</td><td>${h.overdue}</td><td>${h.oldest_due_age_s}</td><td>${h.expired_leases}</td><td>${
    h.dead_letters ?? "sin dato"
  }</td><td>${h.cron_failures}</td><td>${
    h.complete_business_window
      ? `${h.business_failures}/${h.business_total}`
      : "incompleto"
  }</td></tr>`
).join("");
const changes = alerts.map((a) =>
  `<li>${escape(a.observed_at)} <a href="../../${escape(a.runbook)}">${
    escape(a.key)
  }</a>: ${a.state}</li>`
).join("");
await Deno.writeTextFile(
  output.replace(/\.json$/, ".html"),
  `<!doctype html><html lang="es"><meta charset="utf-8"><title>Diagnóstico operativo Dropchat</title><style>body{font:16px system-ui;margin:2rem;max-width:1000px}td,th{padding:.5rem;text-align:left}table{border-collapse:collapse}tr{border-bottom:1px solid #ccc}</style><h1>Diagnóstico operativo</h1><p>${
    escape(start)
  } — ${
    escape(end)
  }</p><p>Duraciones muestreadas; volumen por etapa. HTTP no demuestra éxito de negocio ni entrega.</p><table><thead><tr><th>Etapa/proveedor</th><th>Muestras</th><th>p50 ms</th><th>p95 ms</th><th>p99 ms</th></tr></thead><tbody>${rows}</tbody></table><h2>Salud de colas</h2><table><tr><th>UTC</th><th>Vencidos</th><th>Edad s</th><th>Leases</th><th>Dead letters</th><th>Cron fallidos</th><th>Fallos/total negocio</th></tr>${healthRows}</table><h2>Alertas y recuperación</h2><ul>${changes}</ul><p>Errores de negocio: usar el panel existente /errors. No hay canal de notificación activado.</p></html>`,
);
