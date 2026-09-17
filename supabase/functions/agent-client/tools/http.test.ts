// F08 — the HTTP tool: any URL when config.url is unset, headers chosen by
// the model merged into the request, no timeout, redirects followed.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { requestToolImplementation } from "./http.ts";
import type { RequestContext } from "../protocols/base.ts";

const context = {
  organization: { id: "aaaaaaaa-0000-4000-8000-000000000001" },
  conversation: {
    id: "aaaaaaaa-0000-4000-8000-0000000000c1",
    organization_address: "100000000000001",
    address: "5491100000101",
  },
  agent: { id: "aaaaaaaa-0000-4000-8000-00000000a0a9" },
} as unknown as RequestContext;

const publicDns = (host: string) =>
  Promise.resolve(host === "api.example.com" ? ["93.184.216.34"] : []);

function stubFetch(respond: (req: Request) => Promise<Response>) {
  const realFetch = globalThis.fetch;
  const seen: Request[] = [];
  globalThis.fetch = (input, init) => {
    const req = input instanceof Request ? input : new Request(input, init);
    seen.push(req);
    return respond(req);
  };
  return { seen, restore: () => (globalThis.fetch = realFetch) };
}

Deno.test("F08: the HTTP tool refuses the cloud metadata address without a request", async () => {
  const net = stubFetch(() => Promise.resolve(Response.json({ secret: 1 })));
  try {
    const result = await requestToolImplementation(
      { url: "http://169.254.169.254/latest/meta-data/", method: "GET" },
      {},
      context,
      undefined,
      { resolver: publicDns },
    );
    assertEquals(result.isError, true);
    assertEquals(result.status, 403);
    assertEquals(net.seen.length, 0);
  } finally {
    net.restore();
  }
});

Deno.test("F08: the HTTP tool refuses internal names (kong, *.internal)", async () => {
  const net = stubFetch(() => Promise.resolve(Response.json({})));
  try {
    for (
      const url of [
        "http://kong:8000/rest/v1/",
        "https://db.supabase.internal/",
      ]
    ) {
      const result = await requestToolImplementation(
        { url, method: "GET" },
        {},
        context,
        undefined,
        { resolver: publicDns },
      );
      assertEquals(result.status, 403, url);
    }
    assertEquals(net.seen.length, 0);
  } finally {
    net.restore();
  }
});

Deno.test("F08: headers chosen by the model are not forwarded; config headers are", async () => {
  const net = stubFetch(() => Promise.resolve(Response.json({ ok: true })));
  try {
    const result = await requestToolImplementation(
      {
        url: "https://api.example.com/users",
        method: "POST",
        headers: {
          Authorization: "Bearer stolen",
          apikey: "service-role",
          "Content-Type": "application/json",
        },
        body: { name: "x" },
      },
      { headers: { Authorization: "Bearer configured" } },
      context,
      undefined,
      { resolver: publicDns },
    );
    assertEquals(result.isError, false);
    const sent = net.seen[0].headers;
    assertEquals(sent.get("authorization"), "Bearer configured");
    assertEquals(sent.get("apikey"), null);
    assertEquals(sent.get("content-type"), "application/json");
  } finally {
    net.restore();
  }
});

Deno.test("F08: redirects are not followed (a public URL cannot bounce inward)", async () => {
  const net = stubFetch((req) =>
    Promise.resolve(
      req.url.startsWith("https://api.example.com/")
        ? new Response(null, {
          status: 302,
          headers: { location: "http://169.254.169.254/latest/meta-data/" },
        })
        : Response.json({ secret: 1 }),
    )
  );
  try {
    const result = await requestToolImplementation(
      { url: "https://api.example.com/go", method: "GET" },
      {},
      context,
      undefined,
      { resolver: publicDns },
    );
    assertEquals(net.seen.length, 1);
    assertEquals(result.status, 302);
  } finally {
    net.restore();
  }
});

Deno.test("F08: a hanging endpoint times out", async () => {
  const net = stubFetch((req) =>
    new Promise((_, reject) => {
      req.signal?.addEventListener("abort", () => reject(req.signal.reason));
    })
  );
  try {
    const t0 = performance.now();
    const result = await requestToolImplementation(
      { url: "https://api.example.com/slow", method: "GET" },
      {},
      context,
      undefined,
      { resolver: publicDns, timeoutMs: 100 },
    );
    assert(performance.now() - t0 < 2000);
    assertEquals(result.isError, true);
  } finally {
    net.restore();
  }
});
