// Signs webhook bodies the way Meta and Slack do, so tests can hand a handler
// a request it must accept — and flip one byte to hand it one it must not.
// Test-only: the secrets passed in here are whatever the test decided.

const encoder = new TextEncoder();

async function hmacHex(secret: string, data: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, encoder.encode(data));
  return Array.from(new Uint8Array(mac))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** `X-Hub-Signature-256` for a Meta (WhatsApp / Instagram) webhook body. */
export async function signMeta(body: string, appSecret: string) {
  return `sha256=${await hmacHex(appSecret, body)}`;
}

/** `x-slack-signature` (v0) for a Slack Events API body. */
export async function signSlack(
  body: string,
  signingSecret: string,
  timestamp: number = Math.floor(Date.now() / 1000),
) {
  return {
    signature: `v0=${await hmacHex(signingSecret, `v0:${timestamp}:${body}`)}`,
    timestamp: String(timestamp),
  };
}

/** A POST carrying a Meta-signed JSON body. */
export async function metaRequest(
  url: string,
  payload: unknown,
  appSecret: string,
  init: RequestInit = {},
): Promise<Request> {
  const body = JSON.stringify(payload);
  return new Request(url, {
    method: "POST",
    ...init,
    headers: {
      "content-type": "application/json",
      "X-Hub-Signature-256": await signMeta(body, appSecret),
      ...(init.headers ?? {}),
    },
    body,
  });
}

/** A POST carrying a Slack-signed JSON body. */
export async function slackRequest(
  url: string,
  payload: unknown,
  signingSecret: string,
  timestamp?: number,
): Promise<Request> {
  const body = JSON.stringify(payload);
  const { signature, timestamp: ts } = await signSlack(
    body,
    signingSecret,
    timestamp,
  );
  return new Request(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-slack-signature": signature,
      "x-slack-request-timestamp": ts,
    },
    body,
  });
}
