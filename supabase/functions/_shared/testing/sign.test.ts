import { assertEquals, assertMatch } from "jsr:@std/assert@1";
import { signMeta, signSlack } from "./sign.ts";

// Known vector: HMAC-SHA256("key", "The quick brown fox jumps over the lazy dog")
const VECTOR =
  "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8";

Deno.test("signMeta produces sha256=<hmac hex> over the raw body", async () => {
  assertEquals(
    await signMeta("The quick brown fox jumps over the lazy dog", "key"),
    `sha256=${VECTOR}`,
  );
});

Deno.test("signSlack signs v0:<ts>:<body> and returns the timestamp used", async () => {
  const { signature, timestamp } = await signSlack(
    "body",
    "secret",
    1757000000,
  );
  assertEquals(timestamp, "1757000000");
  assertMatch(signature, /^v0=[0-9a-f]{64}$/);
  // Deterministic for a fixed timestamp.
  const again = await signSlack("body", "secret", 1757000000);
  assertEquals(again.signature, signature);
});
