// T1 — what an organization says about itself, and what of that reaches the
// model.
//
// Written before the module. The subject is not the happy path: it is that
// `organizations.extra` is a free-form jsonb bag written straight to PostgREST
// by any admin's API key, so the screen's validation is advice, not a gate.
// Whatever is in there has to render into a system prompt without throwing and
// without dragging a 40 kB essay into every single call.
//
// Pure: no database, no network.
import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { assertSnapshot } from "jsr:@std/testing@1/snapshot";
import {
  businessProfileBlock,
  parseBusinessProfile,
} from "./business_profile.ts";
import { BUSINESS_PROFILE_LIMITS } from "./types/business_profile.ts";
import type { OrganizationExtra } from "./types/extra_types.ts";

const FULL: OrganizationExtra = {
  business_profile: {
    industry: "Zapatillas urbanas",
    sells: "Zapatillas de calle y running, tallas 35 a 45.",
    shipping_coverage: "Todo Chile continental; retiro en tienda en Ñuñoa.",
    shipping_times: "24 a 48 horas en RM, 3 a 5 días hábiles en regiones.",
    payment_methods: ["Webpay", "Transferencia", "Efectivo contra entrega"],
    returns_policy:
      "Cambio por talla dentro de 30 días con boleta. Sin devolución de dinero.",
    currency: "CLP",
  },
};

Deno.test("T1: an organization that said nothing adds nothing to the prompt", () => {
  assertEquals(businessProfileBlock(null), null);
  assertEquals(businessProfileBlock(undefined), null);
  assertEquals(businessProfileBlock({}), null);
  assertEquals(businessProfileBlock({ business_profile: {} }), null);
});

Deno.test("T1: the full profile, as the model reads it", async (t) => {
  await assertSnapshot(t, businessProfileBlock(FULL));
});

Deno.test("T1: only what was filled in is rendered, and always in the same order", () => {
  // Written back to front on purpose: the order of the block is the module's,
  // not the order somebody's JSON happened to have.
  const block = businessProfileBlock({
    business_profile: {
      currency: "CLP",
      payment_methods: ["Transferencia"],
      industry: "Panadería",
    },
  });

  assertEquals(
    block,
    [
      "Perfil del negocio:",
      "- Rubro: Panadería",
      "- Medios de pago: Transferencia",
      "- Moneda: CLP (peso chileno)",
    ].join("\n"),
  );
});

// ---------------------------------------------------------------------------
// The half that matters: nonsense written past the screen.
// ---------------------------------------------------------------------------

Deno.test("T1: one bad field does not erase the rest of the profile", () => {
  const { profile, dropped } = parseBusinessProfile({
    business_profile: {
      industry: "Panadería",
      // Past the limit, which is the shape a paste takes.
      sells: "a".repeat(BUSINESS_PROFILE_LIMITS.sells + 1),
    },
  });

  assertEquals(dropped, ["sells"]);
  assertEquals(profile, { industry: "Panadería" });
});

Deno.test("T1: a profile that is not an object is not a profile", () => {
  for (const value of ["texto", 3, true, [], null]) {
    const extra = { business_profile: value } as unknown as OrganizationExtra;
    assertEquals(
      businessProfileBlock(extra),
      null,
      `for ${JSON.stringify(value)}`,
    );
  }
});

Deno.test("T1: a field of the wrong type is dropped, not rendered", () => {
  const { profile, dropped } = parseBusinessProfile({
    business_profile: {
      industry: "Panadería",
      payment_methods: "transferencia",
      shipping_times: 48,
      currency: "COP",
    },
  } as unknown as OrganizationExtra);

  assertEquals(dropped.sort(), [
    "currency",
    "payment_methods",
    "shipping_times",
  ]);
  assertEquals(profile, { industry: "Panadería" });
});

Deno.test("T1: a list of payment methods is not a place to hide an essay", () => {
  const { profile, dropped } = parseBusinessProfile({
    business_profile: {
      payment_methods: [
        "Webpay",
        "b".repeat(BUSINESS_PROFILE_LIMITS.payment_method + 1),
      ],
    },
  });

  // The list is written whole (a JSON merge patch replaces an array in one
  // piece), so it is judged whole: a bad item drops the list, not the item.
  assertEquals(dropped, ["payment_methods"]);
  assertEquals(profile, {});
});

Deno.test("T1: blank is the same as absent", () => {
  const { profile } = parseBusinessProfile({
    business_profile: {
      industry: "   ",
      sells: "",
      payment_methods: [],
      returns_policy: "  Cambios dentro de 30 días.  ",
    },
  });

  assertEquals(profile, { returns_policy: "Cambios dentro de 30 días." });
});

Deno.test("T1: a key nobody declared never reaches the model", () => {
  const block = businessProfileBlock({
    business_profile: {
      industry: "Panadería",
      // The shape of a mistake that matters: `extra` is where the tokens of
      // this organization live, and the prompt is the one place that gets
      // copied into somebody else's logs.
      api_key: "sk-no-deberia-viajar-0000",
    },
  } as unknown as OrganizationExtra);

  assertEquals(block, "Perfil del negocio:\n- Rubro: Panadería");
});

Deno.test("T1: the profile is named, so the model does not read it as an order", async (t) => {
  const block = businessProfileBlock(FULL)!;

  // The block is data about the business, not instructions to the agent: it
  // has to arrive labelled, or a line like "Sin devolución de dinero" reads as
  // something the agent was told to say.
  assertStringIncludes(block, "Perfil del negocio:");
  await assertSnapshot(t, parseBusinessProfile(FULL));
});
