// T5 — what a drill's transcript is judged against, deterministically.
//
// The item is explicit that there are two kinds of expectation and that they
// do not have the same authority: a rubric with an LLM judge has variance and
// cannot put CI in red, so the DETERMINISTIC ones are the gate. This module is
// that gate: no model, no network, no clock, no database.
//
// The one rule that shapes everything here: only what the AGENT said counts.
// A test whose own question contains the phrase it looks for is a test of
// nothing, and that mistake is invisible in a transcript read by eye.
import type { EscalationCategory } from "./types/message_types.ts";

/** One thing that happened in the drill. */
export type TranscriptEntry = {
  role: "customer" | "agent";
  text?: string;
  /** A tool the agent called, as `type:label` — the identity T6 merges by. */
  tool?: string;
  /** Present when the agent handed the conversation to a person (H3). */
  escalation?: { category?: EscalationCategory | string };
};

export type Transcript = TranscriptEntry[];

export type Expectations = {
  /** Text, or a regex written as `/…/flags`. */
  must_include?: string[];
  must_not_include?: string[];
  /** `true`, `false`, or the category the handover must carry. */
  expect_escalation?: boolean | { category?: string };
  /** A tool identity, `type:label`. */
  expect_tool_call?: string;
};

export type Verdict = {
  total: number;
  passed: number;
  /** One sentence per failed expectation, in Spanish, for the panel. */
  failures: string[];
};

/** `/…/flags` is a regular expression; anything else is literal text. */
function asRegExp(pattern: string): RegExp | null {
  const match = /^\/(.*)\/([gimsuy]*)$/s.exec(pattern);

  if (!match) return null;

  // A broken pattern is a broken TEST. Returning a literal matcher instead
  // would turn a typo into a silent pass.
  return new RegExp(match[1], match[2]);
}

function saidIt(said: string, pattern: string): boolean {
  const expression = asRegExp(pattern);

  return expression ? expression.test(said) : said.includes(pattern);
}

export function evaluateExpectations(
  expectations: Expectations,
  transcript: Transcript,
): Verdict {
  const failures: string[] = [];
  let total = 0;

  // Only the agent's own words. The customer's turns are the input.
  const said = transcript
    .filter((entry) => entry.role === "agent" && entry.text)
    .map((entry) => entry.text)
    .join("\n");

  const check = (ok: boolean, failure: string) => {
    total += 1;
    if (!ok) failures.push(failure);
  };

  for (const pattern of expectations.must_include ?? []) {
    try {
      check(saidIt(said, pattern), `no dijo ${JSON.stringify(pattern)}`);
    } catch {
      check(false, `${JSON.stringify(pattern)} no es una expresión regular`);
    }
  }

  for (const pattern of expectations.must_not_include ?? []) {
    try {
      check(
        !saidIt(said, pattern),
        `dijo ${JSON.stringify(pattern)} y no debía`,
      );
    } catch {
      check(false, `${JSON.stringify(pattern)} no es una expresión regular`);
    }
  }

  const escalation = transcript.find((entry) => entry.escalation)?.escalation;
  const expected = expectations.expect_escalation;

  if (expected === true) {
    check(!!escalation, "no derivó a una persona");
  } else if (expected === false) {
    check(!escalation, "derivó a una persona y no debía");
  } else if (expected && typeof expected === "object") {
    if (!escalation) {
      check(false, "no derivó a una persona");
    } else if (expected.category) {
      check(
        escalation.category === expected.category,
        `derivó por ${
          JSON.stringify(escalation.category ?? null)
        } y se esperaba ${JSON.stringify(expected.category)}`,
      );
    } else {
      check(true, "");
    }
  }

  if (expectations.expect_tool_call) {
    check(
      transcript.some((entry) => entry.tool === expectations.expect_tool_call),
      `no llamó a la herramienta ${
        JSON.stringify(expectations.expect_tool_call)
      }`,
    );
  }

  return { total, passed: total - failures.length, failures };
}
