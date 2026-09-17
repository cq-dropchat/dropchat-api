// F19 — Meta webhooks with several apps configured (`META_APP_ID` /
// `META_APP_SECRET`, `|`-separated). Without `?app_id=` in the callback URL
// the handlers checked only the FIRST app's secret: a second app pointed at
// the same URL never validated, and its messages were acked with 200 and
// dropped without an error anywhere.
import "./testing/env.ts"; // before the handlers: keys are read at import
import { assert, assertEquals } from "jsr:@std/assert@1";
import { signMeta } from "./testing/sign.ts";
import { verifyMetaSignature } from "./meta_signature.ts";
import { handler as whatsappWebhook } from "../whatsapp-webhook/index.ts";
import { handler as instagramWebhook } from "../instagram-webhook/index.ts";

const APPS = {
  appIds: "100000000000000|100000000000002",
  appSecrets: "meta-app-secret-test|meta-app-secret-second-test",
};
const BODY = JSON.stringify({ object: "whatsapp_business_account", entry: [] });

// ---------------------------------------------------------------------------
// The verifier.
// ---------------------------------------------------------------------------

Deno.test("F19: without app_id, a body signed by the second app is valid", async () => {
  const result = await verifyMetaSignature(
    BODY,
    await signMeta(BODY, "meta-app-secret-second-test"),
    { ...APPS, appId: null },
  );
  assertEquals(result, { valid: true, appId: "100000000000002" });
});

Deno.test("F19: app_id still pins the secret it names", async () => {
  const signedBySecond = await signMeta(BODY, "meta-app-secret-second-test");

  assertEquals(
    await verifyMetaSignature(BODY, signedBySecond, {
      ...APPS,
      appId: "100000000000000",
    }),
    { valid: false, reason: "signature_mismatch" },
  );
  assertEquals(
    await verifyMetaSignature(BODY, signedBySecond, {
      ...APPS,
      appId: "999",
    }),
    { valid: false, reason: "unknown_app_id" },
  );
});

Deno.test("F19: failures say why", async () => {
  assertEquals(
    await verifyMetaSignature(BODY, null, { ...APPS, appId: null }),
    { valid: false, reason: "missing_signature" },
  );
  assertEquals(
    await verifyMetaSignature(BODY, "sha256=00", { ...APPS, appId: null }),
    { valid: false, reason: "signature_mismatch" },
  );
  assertEquals(
    await verifyMetaSignature(BODY, await signMeta(BODY, "x"), {
      appIds: "1|2",
      appSecrets: "only-one",
      appId: null,
    }),
    { valid: false, reason: "misconfigured" },
  );
  assertEquals(
    await verifyMetaSignature(BODY, await signMeta(BODY, "x"), {
      appIds: undefined,
      appSecrets: undefined,
      appId: null,
    }),
    { valid: false, reason: "misconfigured" },
  );
});

// ---------------------------------------------------------------------------
// The handlers, with two apps configured.
// ---------------------------------------------------------------------------

function withEnv(vars: Record<string, string>) {
  const previous = Object.fromEntries(
    Object.keys(vars).map((k) => [k, Deno.env.get(k)]),
  );
  for (const [k, v] of Object.entries(vars)) Deno.env.set(k, v);
  return () => {
    for (const [k, v] of Object.entries(previous)) {
      if (v === undefined) Deno.env.delete(k);
      else Deno.env.set(k, v);
    }
  };
}

function captureRuntimeAndLogs() {
  const pending: Promise<unknown>[] = [];
  const g = globalThis as unknown as { EdgeRuntime?: unknown };
  const previousRuntime = g.EdgeRuntime;
  g.EdgeRuntime = { waitUntil: (p: Promise<unknown>) => pending.push(p) };
  const errors: string[] = [];
  const originalError = console.error;
  const originalLog = console.log;
  const originalWarn = console.warn;
  console.error = (...args: unknown[]) =>
    errors.push(args.map(String).join(" "));
  console.log = () => {};
  console.warn = () => {};
  return {
    pending,
    errors,
    restore: () => {
      g.EdgeRuntime = previousRuntime;
      console.error = originalError;
      console.log = originalLog;
      console.warn = originalWarn;
    },
  };
}

// Payloads no organization has connected: accepted work ends without rows.
const WHATSAPP_PAYLOAD = {
  object: "whatsapp_business_account",
  entry: [{
    id: "399999999999999",
    changes: [{
      field: "messages",
      value: {
        messaging_product: "whatsapp",
        metadata: {
          display_phone_number: "5490000000000",
          phone_number_id: "999999999999999",
        },
        statuses: [],
      },
    }],
  }],
};
const INSTAGRAM_PAYLOAD = { object: "instagram", entry: [] };

async function post(
  handler: (req: Request) => Promise<Response> | Response,
  path: string,
  payload: unknown,
  secret: string,
) {
  const body = JSON.stringify(payload);
  const capture = captureRuntimeAndLogs();
  try {
    const response = await handler(
      new Request(`http://localhost/${path}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "X-Hub-Signature-256": await signMeta(body, secret),
        },
        body,
      }),
    );
    await Promise.allSettled(capture.pending);
    return {
      status: response.status,
      accepted: capture.pending.length > 0,
      errors: capture.errors,
    };
  } finally {
    capture.restore();
  }
}

for (
  const [name, handler, path, payload, idVar, secretVar] of [
    [
      "whatsapp-webhook",
      whatsappWebhook,
      "whatsapp-webhook",
      WHATSAPP_PAYLOAD,
      "META_APP_ID",
      "META_APP_SECRET",
    ],
    [
      "instagram-webhook",
      instagramWebhook,
      "instagram-webhook",
      INSTAGRAM_PAYLOAD,
      "INSTAGRAM_APP_ID",
      "INSTAGRAM_APP_SECRET",
    ],
  ] as const
) {
  Deno.test({
    name:
      `F19: ${name} accepts a request from the second configured app without app_id`,
    sanitizeResources: false,
    sanitizeOps: false,
    async fn() {
      const restore = withEnv({
        [idVar]: APPS.appIds,
        [secretVar]: APPS.appSecrets,
      });
      try {
        const result = await post(
          handler,
          path,
          payload,
          "meta-app-secret-second-test",
        );
        assertEquals(result.status, 200);
        assert(result.accepted, "the second app's request was dropped");
      } finally {
        restore();
      }
    },
  });

  Deno.test({
    name: `F19: ${name} logs an error when a request matches no configured app`,
    sanitizeResources: false,
    sanitizeOps: false,
    async fn() {
      const restore = withEnv({
        [idVar]: APPS.appIds,
        [secretVar]: APPS.appSecrets,
      });
      try {
        const result = await post(handler, path, payload, "not-a-secret");
        assertEquals(result.status, 200); // Meta must not retry
        assertEquals(result.accepted, false);

        const lines = result.errors.map((l) => JSON.parse(l));
        const line = lines.find((l) => /signature/i.test(l.msg));
        assert(line, `no error log: ${JSON.stringify(result.errors)}`);
        assertEquals(line.level, "error");
        assertEquals(line.reason, "signature_mismatch");
        assertEquals(line.apps_configured, 2);
        // Nothing derived from a secret reaches the logs.
        assert(!JSON.stringify(line).includes("expected"));
      } finally {
        restore();
      }
    },
  });
}
