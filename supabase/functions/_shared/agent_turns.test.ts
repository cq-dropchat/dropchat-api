// F16: concurrent agent-client invocations in one conversation, against a
// local Supabase with supabase/tests/fixtures loaded. `invoke` below is the
// turn skeleton of agent-client — register, debounce, claim, answer, release
// — with the LLM replaced by a counter.
import { assertEquals } from "jsr:@std/assert@1";
import { createClient } from "@supabase/supabase-js";
import type { Database } from "./types/database_types.ts";
import { env, fixture, supabaseIsUp } from "./testing/env.ts";
import {
  beginAgentTurn,
  releaseAgentTurn,
  renewAgentTurn,
  type TurnMessage,
  waitForAgentTurn,
} from "./agent_turns.ts";

const up = await supabaseIsUp();

function service() {
  return createClient<Database>(env.url, env.serviceRoleKey, {
    auth: { persistSession: false },
  });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function message(offsetMs: number): TurnMessage {
  return {
    conversation_id: fixture.convA1,
    id: crypto.randomUUID(),
    created_at: new Date(Date.now() + offsetMs).toISOString(),
  };
}

async function resetTurn(client: ReturnType<typeof service>) {
  await client.from("agent_turns").delete().eq(
    "conversation_id",
    fixture.convA1,
  );
}

type Answers = {
  count: number;
  answered: string[];
  active?: number;
  maxActive?: number;
};

async function invoke(
  client: ReturnType<typeof service>,
  msg: TurnMessage,
  answers: Answers,
  { delayMs = 150, answerMs = 50, steps = 1 } = {},
) {
  await beginAgentTurn(client, msg);
  await sleep(delayMs);

  const claim = await waitForAgentTurn(client, msg, {
    pollMs: 25,
    maxWaitMs: 5000,
  });
  if (claim !== "claimed") return claim;

  for (let step = 0; step < steps; step++) {
    // Before every paid call.
    if (await renewAgentTurn(client, msg) !== "renewed") {
      await releaseAgentTurn(client, msg, false);
      return "yielded";
    }
    answers.count++;
    answers.active = (answers.active ?? 0) + 1;
    answers.maxActive = Math.max(answers.maxActive ?? 0, answers.active);
    await sleep(answerMs);
    answers.active--;
  }

  answers.answered.push(msg.id);
  await releaseAgentTurn(client, msg, true);
  return "answered";
}

Deno.test({
  name:
    "F16: two messages inserted together in one conversation get one answer",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    await resetTurn(client);
    const answers: Answers = { count: 0, answered: [] };

    try {
      const m1 = message(0);
      const m2 = message(5);

      // Both invocations start at once, and the older one registers last.
      const results = await Promise.all([
        sleep(20).then(() => invoke(client, m1, answers)),
        invoke(client, m2, answers),
      ]);

      assertEquals(results, ["superseded", "answered"]);
      assertEquals(answers.count, 1);
      assertEquals(answers.answered, [m2.id]);
    } finally {
      await resetTurn(client);
    }
  },
});

Deno.test({
  name: "F16: a duplicate invocation of the same message answers once",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    await resetTurn(client);
    const answers: Answers = { count: 0, answered: [] };

    try {
      const m = message(0);
      const results = await Promise.all([
        invoke(client, m, answers),
        invoke(client, m, answers),
      ]);

      assertEquals(results.sort(), ["answered", "handled"]);
      assertEquals(answers.count, 1);
    } finally {
      await resetTurn(client);
    }
  },
});

Deno.test({
  name:
    "F16: a message arriving mid-answer stops the holder before its next call and is answered after it",
  ignore: !up,
  sanitizeResources: false,
  sanitizeOps: false,
  async fn() {
    const client = service();
    await resetTurn(client);
    const answers: Answers = { count: 0, answered: [] };

    try {
      const m1 = message(0);
      // m1 runs a three-step tool loop; m2 lands during its first step.
      const first = invoke(client, m1, answers, {
        delayMs: 0,
        answerMs: 300,
        steps: 3,
      });
      await sleep(100);
      const m2 = message(0);
      const second = invoke(client, m2, answers, { delayMs: 0 });

      assertEquals(await Promise.all([first, second]), [
        "yielded",
        "answered",
      ]);
      // m1 paid for one step, not three, and the two never ran together.
      assertEquals(answers.count, 2);
      assertEquals(answers.maxActive, 1);
      assertEquals(answers.answered, [m2.id]);
    } finally {
      await resetTurn(client);
    }
  },
});
