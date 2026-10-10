// LOCAL ONLY: real pg_net, queue, agent and billing; the LLM alone is fake.
import "../../functions/_shared/testing/env.ts";
import postgres from "postgres";
import { createClient } from "@supabase/supabase-js";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { edgeRuntimeIsUp, env } from "../../functions/_shared/testing/env.ts";
import { handler as agent } from "../../functions/agent-client/index.ts";
import { withRequestLogging } from "../../functions/_shared/logger.ts";
import type { Database } from "../../functions/_shared/types/database_types.ts";
if (env.url !== "http://127.0.0.1:54321" || await edgeRuntimeIsUp()) {
  throw new Error("Disposable local stack without edge-runtime required");
}
const sql = postgres(
  "postgresql://postgres:postgres@127.0.0.1:54322/postgres",
  { max: 4 },
);
const client = createClient<Database>(env.url, env.serviceRoleKey, {
  auth: { persistSession: false },
});
const prefix = "e5000000-";
const org = (n: number) =>
  `e5000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const conv = (n: number) =>
  `e5000000-0000-4000-8001-${String(n).padStart(12, "0")}`;
const tenant = (n: number) => n % 50 < 10 ? 2 + n % 50 : 1;
const smoke = Deno.args.includes("--smoke");
const phases = smoke
  ? [{ rate: 1, seconds: 15 }]
  : [{ rate: 3, seconds: 120 }, { rate: 6, seconds: 120 }, {
    rate: 9,
    seconds: 120,
  }, { rate: 12, seconds: 300 }];
const volume = phases.reduce((n, p) => n + p.rate * p.seconds, 0);
const savedFetch = globalThis.fetch;
const arrivals = new Map<string, number>();
const waits = new Map<number, number[]>();
const execution: number[] = [];
const snapshots: unknown[] = [];
const errors: string[] = [];
let active = 0,
  peak = 0,
  startedWorkers = 0,
  finished = 0,
  offered = 0,
  inserted = 0,
  stop = false;
const slots: Array<() => void> = [];
let permits = 8;
const acquire = async () => {
  if (permits > 0) {
    permits--;
    return;
  }
  await new Promise<void>((resolve) => slots.push(resolve));
};
const release = () => {
  const next = slots.shift();
  if (next) next();
  else permits++;
};
const pending = new Set<Promise<Response>>();
let server: ReturnType<typeof Deno.serve> | undefined;
let tick: Promise<void> | undefined;
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const secrets =
  await sql`select id,name,decrypted_secret from vault.decrypted_secrets where name in ('edge_functions_url','edge_functions_token')`;
const cron = await sql`select jobid,active from cron.job`;
const quantile = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * p) - 1)] ?? null;
};
await Deno.mkdir("artifacts/queue-workers", { recursive: true });
try {
  assertEquals(secrets.length, 2, "Local Vault config required");
  const [foreign] =
    await sql`select count(*)::int as n from public.edge_calls where status in ('pending','sending')`;
  assertEquals(
    foreign.n,
    0,
    "Use a freshly reset disposable DB; do not alter unrelated active work",
  );
  for (const job of cron) {
    if (
      job.active
    ) await sql`select cron.alter_job(${job.jobid}, active := false)`;
  }
  for (let n = 1; n <= 11; n++) {
    await client.from("organizations").insert({
      id: org(n),
      name: `queue-capacity-${n}`,
    }).throwOnError();
    await client.from("organizations_addresses").insert({
      organization_id: org(n),
      service: "sandbox",
      address: `capacity-${n}`,
    }).throwOnError();
    await client.from("agents").insert({
      organization_id: org(n),
      name: "Capacity AI",
      extra: {
        mode: "active",
        protocol: "chat_completions",
        api_url: "https://api.groq.com/openai/v1",
        api_key: "sk-fake-capacity",
        model: "openai/gpt-oss-20b",
        instructions: "Controlled capacity fixture",
        response_delay_seconds: 0,
      },
    }).throwOnError();
  }
  // Fixture generation is outside the measurement. Every measured message
  // insert, claim, answer and commit uses the normal triggers and quota code.
  await sql.unsafe(
    `insert into public.conversations(id,organization_id,service,organization_address,address,name) select ('e5000000-0000-4000-8001-'||lpad(n::text,12,'0'))::uuid,('e5000000-0000-4000-8000-'||lpad((case when n%50<10 then 2+n%50 else 1 end)::text,12,'0'))::uuid,'sandbox','capacity-'||(case when n%50<10 then 2+n%50 else 1 end),'peer-'||n,'Capacity '||n from generate_series(1,${volume}) n`,
  );
  globalThis.fetch = async (input, init) => {
    const url = input instanceof Request ? input.url : String(input);
    if (url.startsWith("https://api.groq.com/")) {
      await sleep(50);
      return Response.json({
        id: `chatcmpl-${crypto.randomUUID()}`,
        object: "chat.completion",
        created: Math.floor(Date.now() / 1000),
        model: "openai/gpt-oss-20b",
        choices: [{
          index: 0,
          message: { role: "assistant", content: "capacity answer" },
          finish_reason: "stop",
        }],
        usage: { prompt_tokens: 10, completion_tokens: 3, total_tokens: 13 },
      });
    }
    if (!url.startsWith(env.url)) {
      throw new Error("Unexpected external request blocked");
    }
    return savedFetch(input, init);
  };
  const work = withRequestLogging("capacity-agent", async (req) => {
    const record = (await req.clone().json()).record;
    if (!record?.organization_id?.startsWith(prefix)) {
      return new Response("Fixture scope required", { status: 403 });
    }
    await acquire();
    active++;
    peak = Math.max(peak, active);
    startedWorkers++;
    const began = performance.now();
    const index = Number(record.organization_id.slice(-12));
    const values = waits.get(index) ?? [];
    values.push(Date.now() - (arrivals.get(record.external_id) ?? Date.now()));
    waits.set(index, values);
    try {
      const response = await agent(req);
      if (!response.ok || response.headers.get("x-business-outcome")) {
        errors.push(
          `agent:${response.status}:${
            response.headers.get("x-business-outcome")
          }`,
        );
      } else finished++;
      return response;
    } catch (error) {
      errors.push(error instanceof Error ? error.name : "unknown");
      return new Response("Fixture worker failed", { status: 503 });
    } finally {
      execution.push(performance.now() - began);
      active--;
      release();
    }
  });
  server = Deno.serve(
    { hostname: "0.0.0.0", port: 8765, onListen: () => {} },
    (req) => {
      if (new URL(req.url).pathname !== "/agent-client") {
        return new Response("Fixture route only", { status: 404 });
      }
      const promise = work(req);
      pending.add(promise);
      promise.then(
        () => pending.delete(promise),
        () => pending.delete(promise),
      );
      return promise;
    },
  );
  for (const secret of secrets) {
    await sql`select vault.update_secret(${secret.id},${
      secret.name === "edge_functions_url"
        ? "http://host.docker.internal:8765"
        : env.serviceRoleKey
    })`;
  }
  tick = (async () => {
    while (!stop) {
      const before = performance.now();
      const result = await sql`select public.deliver_edge_calls() as result`;
      snapshots.push({
        observed_at: new Date().toISOString(),
        tick_ms: performance.now() - before,
        result: result[0].result,
        active,
        finished,
        inserted,
      });
      await sleep(5000);
    }
  })();
  let sequence = 0;
  const phaseResults: unknown[] = [];
  for (const phase of phases) {
    const start = Date.now();
    const before = inserted;
    for (let n = 0; n < phase.rate * phase.seconds; n++) {
      await sleep(Math.max(0, start + n * 1000 / phase.rate - Date.now()));
      sequence++;
      offered++;
      const external = `queue-capacity-${sequence}`;
      arrivals.set(external, Date.now());
      await client.from("messages").insert({
        organization_id: org(tenant(sequence)),
        conversation_id: conv(sequence),
        service: "sandbox",
        organization_address: `capacity-${tenant(sequence)}`,
        conversation_address: `peer-${sequence}`,
        sender_address: `peer-${sequence}`,
        external_id: external,
        content: {
          version: "1",
          type: "text",
          kind: "text",
          text: "capacity input",
        },
      }).throwOnError();
      inserted++;
      if (errors.length) throw new Error(`Worker failed: ${errors.at(-1)}`);
    }
    phaseResults.push({
      offered_rate: phase.rate,
      duration_s: (Date.now() - start) / 1000,
      inserted: inserted - before,
      finished,
      active,
    });
    await Deno.writeTextFile(
      "artifacts/queue-workers/progress.json",
      JSON.stringify({ phases: phaseResults, snapshots, errors }, null, 2),
    );
  }
  const drain = Date.now();
  while (
    finished < inserted && Date.now() - drain < 120000 && !errors.length
  ) await sleep(100);
  assertEquals(errors, []);
  assertEquals(finished, inserted, "All accepted work finishes after burst");
  stop = true;
  await tick;
  await Promise.all(pending);
  await sql`select public.settle_edge_calls()`;
  const [counts] =
    await sql`select count(*) filter(where sender_address is not null)::int as incoming,count(*) filter(where sender_address is null and content->>'text'='capacity answer')::int as answers from public.messages where organization_id::text like 'e5000000-%'`;
  assertEquals(counts.incoming, inserted);
  assertEquals(counts.answers, inserted);
  const usage =
    await sql`select product_id,interval,sum(quantity)::int as quantity from billing.usage where organization_id::text like 'e5000000-%' and product_id in ('messages','messages_inbound') group by product_id,interval`;
  assertEquals(usage.length, 6, "Two products, all three billing intervals");
  assert(peak <= 8, "Configured worker concurrency is respected");
  for (const values of waits.values()) {
    assert(
      (quantile(values, .95) ?? Infinity) <= 10000,
      "Provisional queue wait p95 <= 10 seconds",
    );
  }
  assert(
    usage.every((row) => row.quantity === inserted),
    "All billing intervals match real armed rows",
  );
  const report = {
    qualification: smoke
      ? "15-second wiring smoke; not sustained capacity"
      : "local provisional agent capacity: peak assumption 6/s, 50/100/150% and 2x for five minutes; fake 50ms LLM; eight real concurrent workers; not production peak or provider delivery",
    phases: phaseResults,
    offered,
    inserted,
    finished,
    peak_workers: peak,
    started_workers: startedWorkers,
    execution_p95_ms: quantile(execution, .95),
    wait_by_tenant: [...waits].map(([tenant, values]) => ({
      tenant,
      samples: values.length,
      p95_ms: quantile(values, .95),
      max_ms: Math.max(...values),
    })),
    drain_ms: Date.now() - drain,
    counts,
    usage,
    snapshots,
    errors,
  };
  await Deno.writeTextFile(
    `artifacts/queue-workers/${smoke ? "smoke" : "ramp"}.json`,
    JSON.stringify(report, null, 2),
  );
  console.log(
    "QUEUE_RESULT " +
      JSON.stringify({ inserted, finished, peak, drain_ms: report.drain_ms }),
  );
} finally {
  stop = true;
  await tick?.catch(() => {});
  await Promise.allSettled(pending);
  for (const secret of secrets) {
    await sql`select vault.update_secret(${secret.id},${secret.decrypted_secret})`;
  }
  await server?.shutdown();
  globalThis.fetch = savedFetch;
  await sql`delete from public.messages where organization_id::text like 'e5000000-%'`;
  await sql.begin(async (transaction) => {
    // postgres.js omits the transaction call signature in its Deno types.
    const tx = transaction as unknown as typeof sql;
    await tx`select set_config('app.deletion_sweep','on',true)`;
    await tx`delete from public.organizations where id::text like 'e5000000-%'`;
  });
  for (const job of cron) {
    await sql`select cron.alter_job(${job.jobid}, active := ${job.active})`;
  }
  await sql.end();
}
