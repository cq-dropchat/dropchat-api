import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  assertPublicHost,
  assertPublicUrl,
  DestinationError,
  isBlockedHostname,
  isPrivateAddress,
  type Resolver,
} from "./net_guard.ts";

// F08: an admin of one tenant points an agent tool (SQL, HTTP, MCP) at the
// platform's own network — the database host, Kong, the cloud metadata
// address — and the Edge Function connects from inside it.

const resolver = (table: Record<string, string[]>): Resolver => (host) =>
  Promise.resolve(table[host] ?? []);

Deno.test("F08: private, loopback, link-local and reserved addresses", () => {
  for (
    const ip of [
      "127.0.0.1",
      "10.1.2.3",
      "172.16.0.1",
      "172.31.255.255",
      "192.168.1.1",
      "169.254.169.254",
      "100.64.0.1",
      "0.0.0.0",
      "224.0.0.1",
      "::1",
      "::",
      "fe80::1",
      "fd00::1",
      "::ffff:127.0.0.1",
      "::ffff:10.0.0.1",
    ]
  ) {
    assert(isPrivateAddress(ip), `${ip} should be private`);
  }
  for (const ip of ["8.8.8.8", "172.32.0.1", "93.184.216.34", "2606:4700::1"]) {
    assert(!isPrivateAddress(ip), `${ip} should be public`);
  }
});

Deno.test("F08: internal names are refused before DNS", () => {
  for (
    const host of [
      "localhost",
      "api.localhost",
      "db.supabase.internal",
      "metadata.google.internal",
      "kong",
      "db",
      "printer.local",
    ]
  ) {
    assert(isBlockedHostname(host), `${host} should be blocked`);
  }
  assert(!isBlockedHostname("erp.example.com"));
});

Deno.test("F08: a public name that resolves to a private address is refused", async () => {
  const dns = resolver({
    "erp.example.com": ["93.184.216.34"],
    "sneaky.example.com": ["93.184.216.34", "10.0.0.7"],
    "gone.example.com": [],
  });

  await assertPublicHost("erp.example.com", { resolver: dns });
  await assertRejects(
    () => assertPublicHost("sneaky.example.com", { resolver: dns }),
    DestinationError,
    "10.0.0.7",
  );
  await assertRejects(
    () => assertPublicHost("gone.example.com", { resolver: dns }),
    DestinationError,
    "does not resolve",
  );
  await assertRejects(
    () => assertPublicHost("169.254.169.254", { resolver: dns }),
    DestinationError,
  );
});

Deno.test("F08: URL scheme and host checks", async () => {
  const dns = resolver({ "api.example.com": ["93.184.216.34"] });

  const url = await assertPublicUrl("https://api.example.com/v1", {
    resolver: dns,
  });
  assertEquals(url.hostname, "api.example.com");

  await assertRejects(
    () => assertPublicUrl("file:///etc/passwd", { resolver: dns }),
    DestinationError,
    "scheme",
  );
  await assertRejects(
    () => assertPublicUrl("http://kong:8000/rest/v1/", { resolver: dns }),
    DestinationError,
  );
  await assertRejects(
    () => assertPublicUrl("not a url", { resolver: dns }),
    DestinationError,
  );
});

Deno.test("F08: an explicit allowlist lets local development through", async () => {
  const dns = resolver({});
  await assertPublicHost("api.supabase.internal", {
    resolver: dns,
    allowedHosts: ["api.supabase.internal"],
  });
  await assertRejects(() =>
    assertPublicHost("db.supabase.internal", {
      resolver: dns,
      allowedHosts: ["api.supabase.internal"],
    })
  );
});
