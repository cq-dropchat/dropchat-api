import * as log from "../_shared/logger.ts";
import { verifyMetaSignature } from "../_shared/meta_signature.ts";

const VERIFY_TOKEN = Deno.env.get("WHATSAPP_VERIFY_TOKEN");

/** Meta's subscription handshake (GET). */
export function verifyToken(request: Request): Response {
  if (!VERIFY_TOKEN) {
    log.warn("WHATSAPP_VERIFY_TOKEN environment variable not set");
  }

  const params = new URL(request.url).searchParams;

  if (
    params.get("hub.mode") === "subscribe" &&
    params.get("hub.verify_token") === VERIFY_TOKEN
  ) {
    return new Response(params.get("hub.challenge"));
  }

  return new Response("Verification failed, tokens do not match", {
    status: 403,
  });
}
/**
 * F19: every configured app is tried unless `?app_id=` names one; a request
 * that matches none is logged as an error (it is still acked: Meta must not
 * retry it). Credentials are read per request.
 */
export async function validateWebhookSignature(
  request: Request,
  body: string,
): Promise<boolean> {
  const appIds = Deno.env.get("META_APP_ID");
  const appId = new URL(request.url).searchParams.get("app_id");

  const result = await verifyMetaSignature(
    body,
    request.headers.get("X-Hub-Signature-256"),
    {
      appIds,
      appSecrets: Deno.env.get("META_APP_SECRET"),
      appId,
    },
  );

  if (!result.valid) {
    log.error(
      "WhatsApp webhook signature did not verify: the request was acked and dropped",
      {
        reason: result.reason,
        app_id_param: appId,
        apps_configured: appIds ? appIds.split("|").length : 0,
      },
    );
  }

  return result.valid;
}
