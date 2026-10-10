// Same real durable webhook, randomized pairs; observation off vs on.
import "../../functions/_shared/testing/env.ts";
import { assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import { edgeRuntimeIsUp, env } from "../../functions/_shared/testing/env.ts";
import { metaRequest } from "../../functions/_shared/testing/sign.ts";
import { handler } from "../../functions/whatsapp-webhook/index.ts";
import {
  telemetryBudget,
  withRequestLogging,
} from "../../functions/_shared/logger.ts";
if (env.url !== "http://127.0.0.1:54321" || await edgeRuntimeIsUp()) {
  throw new Error("Disposable local stack without edge-runtime required");
}
const client = createClient(env.url, env.serviceRoleKey, {
  auth: { persistSession: false },
});
const savedRate = Deno.env.get("TELEMETRY_SUCCESS_SAMPLE_RATE");
const runtime = globalThis as unknown as { EdgeRuntime?: unknown };
const savedRuntime = runtime.EdgeRuntime;
const digests: string[] = [];
const samples: { control: number[]; observed: number[] } = {
  control: [],
  observed: [],
};
const wrapped = withRequestLogging("whatsapp-webhook", handler);
let seed = 42;
const random =
  () => ((seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) / 2 ** 32);
async function run(mode: "control" | "observed") {
  Deno.env.set("TELEMETRY_SUCCESS_SAMPLE_RATE", mode === "control" ? "0" : "1");
  const work: Promise<unknown>[] = [];
  runtime.EdgeRuntime = { waitUntil: (p: Promise<unknown>) => work.push(p) };
  const payload = {
    object: "whatsapp_business_account",
    entry: [],
    capacity_nonce: crypto.randomUUID(),
  };
  const req = await metaRequest(
    "http://localhost/whatsapp-webhook",
    payload,
    env.metaAppSecret,
  );
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(JSON.stringify(payload)),
  );
  digests.push(
    Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0"))
      .join(""),
  );
  const start = performance.now();
  const response = await wrapped(req);
  const elapsed = performance.now() - start;
  assertEquals(response.status, 200);
  await Promise.all(work);
  return elapsed;
}
const quantiles = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  const p = (n: number) => sorted[Math.ceil(sorted.length * n) - 1];
  return {
    samples: values.length,
    p50_ms: p(.5),
    p95_ms: p(.95),
    p99_ms: p(.99),
  };
};
try {
  for (let n = 0; n < 5; n++) {
    await run("control");
    await run("observed");
  }
  for (let n = 0; n < 80; n++) {
    for (
      const mode of (random() < .5
        ? ["control", "observed"]
        : ["observed", "control"]) as Array<"control" | "observed">
    ) {
      samples[mode].push(await run(mode));
    }
  }
  const control = quantiles(samples.control),
    observed = quantiles(samples.observed);
  const increase = 100 * (observed.p95_ms / control.p95_ms - 1);
  const report = {
    qualification:
      "local randomized real durable ACK; event sampling off vs full on; same HTTP logger and database; not pre-ledger ACK or staging latency",
    seed: 42,
    control,
    observed,
    p95_increase_percent: increase,
    event_budget: telemetryBudget(),
    passed: increase <= 5 && telemetryBudget().limited === 0,
    raw_ms: samples,
  };
  await Deno.mkdir("artifacts/telemetry", { recursive: true });
  await Deno.writeTextFile(
    "artifacts/telemetry/latency.json",
    JSON.stringify(report, null, 2),
  );
  console.log(
    "TELEMETRY_RESULT " +
      JSON.stringify({ control, observed, increase, passed: report.passed }),
  );
  if (!report.passed) {
    throw new Error(
      "Observation p95 increased more than 5% or the full-on cohort was limited",
    );
  }
} finally {
  runtime.EdgeRuntime = savedRuntime;
  if (savedRate === undefined) Deno.env.delete("TELEMETRY_SUCCESS_SAMPLE_RATE");
  else Deno.env.set("TELEMETRY_SUCCESS_SAMPLE_RATE", savedRate);
  for (let n = 0; n < digests.length; n += 20) {
    await client.from("webhook_receipts").delete().in(
      "digest",
      digests.slice(n, n + 20),
    ).throwOnError();
  }
}
