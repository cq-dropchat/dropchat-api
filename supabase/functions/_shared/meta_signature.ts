// F19. `X-Hub-Signature-256` verification for Meta webhooks (WhatsApp,
// Instagram) when one deployment serves several Meta apps: `*_APP_ID` and
// `*_APP_SECRET` are `|`-separated lists, index-aligned.
//
// Before: without `?app_id=` in the callback URL only the FIRST secret was
// tried, so a second app pointed at the same URL never validated and its
// messages were acked and dropped silently; and a mismatch logged the
// expected HMAC — a valid signature for that body.
//
// Now: `?app_id=` pins its app; without it every configured secret is tried.
// Comparison is constant-time. The result says which app matched, or why
// nothing did.

export type MetaSignatureResult =
  | { valid: true; appId: string }
  | {
    valid: false;
    reason:
      | "misconfigured"
      | "missing_signature"
      | "unknown_app_id"
      | "signature_mismatch";
  };

const encoder = new TextEncoder();

async function hmacSha256(secret: string, body: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(
    await crypto.subtle.sign("HMAC", key, encoder.encode(body)),
  );
}

function hexToBytes(hex: string): Uint8Array | null {
  if (!/^[0-9a-f]*$/i.test(hex) || hex.length % 2 !== 0) return null;
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export async function verifyMetaSignature(
  body: string,
  signatureHeader: string | null,
  { appIds, appSecrets, appId }: {
    appIds: string | undefined;
    appSecrets: string | undefined;
    /** `?app_id=` from the callback URL, if any. */
    appId: string | null;
  },
): Promise<MetaSignatureResult> {
  const ids = appIds?.split("|") ?? [];
  const secrets = appSecrets?.split("|") ?? [];

  if (!ids.length || !appIds || !appSecrets || ids.length !== secrets.length) {
    return { valid: false, reason: "misconfigured" };
  }

  if (!signatureHeader) {
    return { valid: false, reason: "missing_signature" };
  }

  let candidates = ids.map((_, i) => i);
  if (appId) {
    const index = ids.indexOf(appId);
    if (index === -1) return { valid: false, reason: "unknown_app_id" };
    candidates = [index];
  }

  const received = hexToBytes(signatureHeader.replace(/^sha256=/, ""));

  for (const index of candidates) {
    const expected = await hmacSha256(secrets[index], body);
    if (received && timingSafeEqual(expected, received)) {
      return { valid: true, appId: ids[index] };
    }
  }

  return { valid: false, reason: "signature_mismatch" };
}
