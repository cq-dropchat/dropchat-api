// F06. What an integrator runs on their side to verify an OpenBSP webhook.
//
// Every delivery whose webhook has a token carries
//   x-openbsp-signature: sha256=<hex>
// where <hex> is HMAC-SHA256(key = the webhook's token, message = the raw
// request body, byte for byte). Compare in constant time, and read the body
// as text BEFORE parsing it — a re-serialised JSON object is not the same
// bytes. The same header is produced in SQL by dispatch_webhook_deliveries
// (schemas/04_functions_post_tables/04-04_webhook_delivery.sql), and
// supabase/tests/database/07_webhook_deliveries pins the two together.
//
// This module is published in INTEGRATING.md; keep it dependency-free.

const encoder = new TextEncoder();

export async function signWebhookBody(
  body: string,
  token: string,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(token),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(body));
  const hex = Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `sha256=${hex}`;
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/** True when `signature` (the header value) matches `body` under `token`. */
export async function verifyWebhookSignature(
  body: string,
  signature: string | null | undefined,
  token: string,
): Promise<boolean> {
  if (!signature) return false;
  const expected = await signWebhookBody(body, token);
  return constantTimeEqual(expected, signature.trim());
}

/**
 * Convenience for a fetch-style handler: reads the body as text, verifies
 * the header, and returns the parsed payload — or null when the signature
 * is missing or wrong.
 */
export async function readSignedWebhook<T = unknown>(
  request: Request,
  token: string,
): Promise<
  { payload: T; deliveryId: string | null; event: string | null } | null
> {
  const body = await request.text();
  const ok = await verifyWebhookSignature(
    body,
    request.headers.get("x-openbsp-signature"),
    token,
  );
  if (!ok) return null;
  return {
    payload: JSON.parse(body) as T,
    deliveryId: request.headers.get("x-openbsp-delivery-id"),
    event: request.headers.get("x-openbsp-event"),
  };
}
