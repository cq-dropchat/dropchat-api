import { assertEquals } from "jsr:@std/assert@1";
import {
  readSignedWebhook,
  signWebhookBody,
  verifyWebhookSignature,
} from "./webhook_signature.ts";

// F06: the receiver-side check for x-openbsp-signature. The vector below is
// HMAC-SHA256("key", "The quick brown fox jumps over the lazy dog") — the same
// one _shared/testing/sign.test.ts uses, and what
// `select encode(extensions.hmac(<body>, 'key', 'sha256'), 'hex')` yields in
// the database, which is what dispatch_webhook_deliveries computes.
const BODY = "The quick brown fox jumps over the lazy dog";
const TOKEN = "key";
const VECTOR =
  "sha256=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8";

Deno.test("signWebhookBody matches the pgcrypto hmac vector", async () => {
  assertEquals(await signWebhookBody(BODY, TOKEN), VECTOR);
});

Deno.test("verifyWebhookSignature accepts the right header and refuses the rest", async () => {
  assertEquals(await verifyWebhookSignature(BODY, VECTOR, TOKEN), true);
  assertEquals(await verifyWebhookSignature(BODY, ` ${VECTOR} `, TOKEN), true);
  assertEquals(await verifyWebhookSignature(BODY + " ", VECTOR, TOKEN), false);
  assertEquals(await verifyWebhookSignature(BODY, VECTOR, "other"), false);
  assertEquals(await verifyWebhookSignature(BODY, null, TOKEN), false);
  assertEquals(await verifyWebhookSignature(BODY, "sha256=00", TOKEN), false);
});

Deno.test("readSignedWebhook parses a signed request and rejects a tampered one", async () => {
  const payload = { data: { id: "m1" }, entity: "messages", action: "insert" };
  const body = JSON.stringify(payload);
  const signature = await signWebhookBody(body, "hook-token");

  const good = await readSignedWebhook(
    new Request("https://app.example/hook", {
      method: "POST",
      headers: {
        "x-openbsp-signature": signature,
        "x-openbsp-delivery-id": "d1",
        "x-openbsp-event": "messages.insert",
      },
      body,
    }),
    "hook-token",
  );
  assertEquals(good, { payload, deliveryId: "d1", event: "messages.insert" });

  const tampered = await readSignedWebhook(
    new Request("https://app.example/hook", {
      method: "POST",
      headers: { "x-openbsp-signature": signature },
      body: JSON.stringify({ ...payload, action: "update" }),
    }),
    "hook-token",
  );
  assertEquals(tampered, null);
});
