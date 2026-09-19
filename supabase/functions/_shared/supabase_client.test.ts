// F26 — the request id did not leave the function: the Supabase clients sent
// nothing to PostgREST, so a trigger fired by the write could not tell the
// next function which request it belonged to, and every hop minted its own.
import "./testing/env.ts";
import { assertEquals } from "jsr:@std/assert@1";
import { withRequestLogging } from "./logger.ts";
import {
  createApiClientFromKey,
  createClient,
  createUnsecureClient,
} from "./supabase_client.ts";

// supabase-js starts an auth refresh timer per client.
const leaky = { sanitizeOps: false, sanitizeResources: false };

const REQUEST_ID = "0f26f26f-0000-4000-8000-00000000c001";

/** Records the headers of every request and answers PostgREST-style. */
function recordFetch() {
  const realFetch = globalThis.fetch;
  const seen: Headers[] = [];
  globalThis.fetch = (input, init) => {
    const req = input instanceof Request ? input : new Request(input, init);
    seen.push(req.headers);
    return Promise.resolve(Response.json([]));
  };
  return { seen, restore: () => (globalThis.fetch = realFetch) };
}

function inRequest(fn: () => Promise<unknown>, requestId?: string) {
  const quiet = console.log;
  console.log = () => {};
  const handler = withRequestLogging("test", async () => {
    await fn();
    return new Response();
  });
  return handler(
    new Request("http://localhost/test", {
      headers: requestId ? { "x-request-id": requestId } : {},
    }),
  ).finally(() => (console.log = quiet));
}

const clients = {
  createUnsecureClient: () => createUnsecureClient(),
  createClient: () =>
    createClient(
      new Request("http://localhost", {
        headers: { authorization: "Bearer fake-user-jwt" },
      }),
    ),
  createApiClientFromKey: () => createApiClientFromKey("sk_fake_test_key"),
};

for (const [name, make] of Object.entries(clients)) {
  Deno.test(
    `F26: ${name} sends the current request's x-request-id to PostgREST`,
    leaky,
    async () => {
      const net = recordFetch();
      try {
        // Created inside the request, like the handlers do…
        await inRequest(async () => {
          await make().from("messages").select("id");
        }, REQUEST_ID);
        // …and created before it, like a client kept across requests.
        const early = make();
        await inRequest(async () => {
          await early.from("messages").select("id");
        }, REQUEST_ID);
      } finally {
        net.restore();
      }
      assertEquals(net.seen.map((h) => h.get("x-request-id")), [
        REQUEST_ID,
        REQUEST_ID,
      ]);
    },
  );
}

Deno.test("F26: a minted request id is sent too", leaky, async () => {
  const net = recordFetch();
  let minted: string | null = null;
  try {
    const quiet = console.log;
    console.log = () => {};
    try {
      const response = await withRequestLogging("test", async () => {
        await createUnsecureClient().from("messages").select("id");
        return new Response();
      })(new Request("http://localhost/test"));
      minted = response.headers.get("x-request-id");
    } finally {
      console.log = quiet;
    }
  } finally {
    net.restore();
  }
  assertEquals(net.seen[0].get("x-request-id"), minted);
});

Deno.test("F26: outside a request no x-request-id is sent", leaky, async () => {
  const net = recordFetch();
  try {
    await createUnsecureClient().from("messages").select("id");
  } finally {
    net.restore();
  }
  assertEquals(net.seen[0].get("x-request-id"), null);
});

// The legacy service_role key retires at the end of 2026; a project without
// one still gets its secret keys in SUPABASE_SECRET_KEYS.
Deno.test(
  "createUnsecureClient authenticates with a secret key when no legacy key is set",
  leaky,
  async () => {
    const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
    Deno.env.set(
      "SUPABASE_SECRET_KEYS",
      JSON.stringify({ default: "sb_secret_from_the_dictionary" }),
    );
    const net = recordFetch();
    try {
      await createUnsecureClient().from("messages").select("id");
    } finally {
      net.restore();
      Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", legacy);
      Deno.env.delete("SUPABASE_SECRET_KEYS");
    }
    assertEquals(net.seen[0].get("apikey"), "sb_secret_from_the_dictionary");
  },
);
