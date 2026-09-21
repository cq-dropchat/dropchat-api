// T5 — judging a drill's transcript, deterministically.
//
// The item asks for two kinds of expectation and is explicit about why they
// are not the same thing: a rubric with an LLM judge has variance and cannot
// put CI in red, so the DETERMINISTIC ones are the gate. Everything in this
// file is the gate half — no model, no network, no clock.
//
// Written before the module.
import { assertEquals } from "jsr:@std/assert@1";
import { evaluateExpectations, type Transcript } from "./template_tests.ts";

const SAID = (text: string): Transcript[number] => ({ role: "agent", text });
const ASKED = (text: string): Transcript[number] => ({
  role: "customer",
  text,
});

Deno.test("T5: an expectation nobody wrote passes, and says so", () => {
  const result = evaluateExpectations({}, [SAID("hola")]);

  // Zero of zero is not 100 %: a test with no expectations asserts nothing,
  // and reporting it as a pass is how a suite goes green by being empty.
  assertEquals(result, { total: 0, passed: 0, failures: [] });
});

Deno.test("T5: must_include, as plain text", () => {
  const transcript = [
    ASKED("¿hacen envíos?"),
    SAID("Sí, despachamos a todo Chile."),
  ];

  assertEquals(
    evaluateExpectations({ must_include: ["todo Chile"] }, transcript).passed,
    1,
  );

  // Only what the AGENT said counts. The customer's own words are the input,
  // and a test that passed because its own question contained the phrase would
  // be a test of nothing.
  assertEquals(
    evaluateExpectations({ must_include: ["hacen envíos"] }, transcript),
    {
      total: 1,
      passed: 0,
      failures: ['no dijo "hacen envíos"'],
    },
  );
});

Deno.test("T5: must_include, as a regex", () => {
  const transcript = [SAID("Llega en 3 a 5 días hábiles.")];

  assertEquals(
    evaluateExpectations({ must_include: ["/\\d+ a \\d+ días/"] }, transcript)
      .passed,
    1,
  );

  assertEquals(
    evaluateExpectations({ must_include: ["/\\d+ semanas/"] }, transcript)
      .passed,
    0,
  );

  // Flags are part of the literal, because "/hola/i" is how anybody who has
  // written a regex expects to write one.
  assertEquals(
    evaluateExpectations({ must_include: ["/DÍAS/i"] }, transcript).passed,
    1,
  );
});

Deno.test("T5: a broken regex is a broken test, not a passing one", () => {
  // The alternative — treating it as literal text — turns a typo into a
  // silent pass the day somebody writes "/precio(/".
  const result = evaluateExpectations({ must_include: ["/precio(/"] }, [
    SAID("cuesta $10.000"),
  ]);

  assertEquals(result.passed, 0);
  assertEquals(result.failures.length, 1);
  assertEquals(result.failures[0].includes("expresión regular"), true);
});

Deno.test("T5: must_not_include is what a template is really being tested for", () => {
  // The dangerous answers are the invented ones, so this is the half that
  // catches a template promising what the business never said.
  const transcript = [SAID("Te lo dejo mañana sin costo.")];

  assertEquals(
    evaluateExpectations({ must_not_include: ["sin costo"] }, transcript),
    {
      total: 1,
      passed: 0,
      failures: ['dijo "sin costo" y no debía'],
    },
  );

  assertEquals(
    evaluateExpectations({ must_not_include: ["gratis"] }, transcript).passed,
    1,
  );
});

Deno.test("T5: expecting a handover, with and without a reason", () => {
  const escalated: Transcript = [
    SAID("Eso lo ve una persona del equipo."),
    { role: "agent", escalation: { category: "complaint" } },
  ];

  assertEquals(
    evaluateExpectations({ expect_escalation: true }, escalated).passed,
    1,
  );
  assertEquals(
    evaluateExpectations(
      { expect_escalation: { category: "complaint" } },
      escalated,
    )
      .passed,
    1,
  );
  assertEquals(
    evaluateExpectations(
      { expect_escalation: { category: "sales" } },
      escalated,
    )
      .failures,
    ['derivó por "complaint" y se esperaba "sales"'],
  );

  assertEquals(
    evaluateExpectations({ expect_escalation: true }, [SAID("dale")]).failures,
    ["no derivó a una persona"],
  );

  // And the other direction, which is the one that matters for a template
  // that should be able to answer on its own.
  assertEquals(
    evaluateExpectations({ expect_escalation: false }, escalated).failures,
    ["derivó a una persona y no debía"],
  );
});

Deno.test("T5: expecting a tool call", () => {
  const transcript: Transcript = [
    { role: "agent", tool: "sql:pedidos" },
    SAID("Tu pedido salió ayer."),
  ];

  assertEquals(
    evaluateExpectations({ expect_tool_call: "sql:pedidos" }, transcript)
      .passed,
    1,
  );
  assertEquals(
    evaluateExpectations({ expect_tool_call: "http:erp" }, transcript).failures,
    ['no llamó a la herramienta "http:erp"'],
  );
});

Deno.test("T5: every expectation is counted, and the failures name each one", () => {
  const result = evaluateExpectations(
    {
      must_include: ["despacho", "/boleta/"],
      must_not_include: ["gratis"],
      expect_escalation: false,
      expect_tool_call: "sql:pedidos",
    },
    [SAID("El despacho es gratis y va con boleta.")],
  );

  assertEquals(result.total, 5);
  assertEquals(result.passed, 3);
  assertEquals(result.failures, [
    'dijo "gratis" y no debía',
    'no llamó a la herramienta "sql:pedidos"',
  ]);
});
