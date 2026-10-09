// WhatsApp Cloud API webhook: verified and acked here, processed after the
// ack. F29: split from one 1,275-line file into
//   verify.ts            subscription handshake and signature
//   process.ts           the walk over entries and changes
//   changes/*.ts         one module per change field
//   mappers/messages.ts  webhook message → content v1; edits and revokes
//   media.ts             Graph media → storage
//   persist.ts           upserts, then edits and revokes
//   org_addresses.ts     phone number id → account
import { hasWaitUntil, waitUntil } from "../_shared/edge_runtime.ts";
import * as log from "../_shared/logger.ts";
import { withRequestLogging } from "../_shared/logger.ts";
import {
  createUnsecureClient,
  type MetaWebhookPayload,
} from "../_shared/supabase.ts";
import { processReceipt, receive } from "./receipts.ts";
import { validateWebhookSignature, verifyToken } from "./verify.ts";

export { processPayload } from "./process.ts";

export async function handler(request: Request): Promise<Response> {
  switch (request.method) {
    case "GET":
      return verifyToken(request);
    case "POST":
      return await processMessage(request);
  }

  return new Response("Method not implemented", { status: 501 });
}

if (import.meta.main) {
  Deno.serve(withRequestLogging("whatsapp-webhook", handler));
}

async function processMessage(request: Request): Promise<Response> {
  const body = await request.text();

  // Validate that the request comes from Meta
  const isValidSignature = await validateWebhookSignature(request, body);

  if (!isValidSignature) {
    // Return 200 to prevent Meta from retrying. Common cause: the user deleted
    // their org but didn't remove the webhook from their Meta app configuration.
    return new Response();
  }

  const payload = JSON.parse(body) as MetaWebhookPayload;

  if (payload.object !== "whatsapp_business_account") {
    return new Response("Unexpected object", { status: 400 });
  }

  log.event("webhook.validated", "success", { provider: "whatsapp" });
  const client = createUnsecureClient();
  let id: string;
  try {
    id = await receive(client, body, payload);
  } catch {
    log.event("webhook.queued", "failure", { provider: "whatsapp" });
    return new Response("Durable reception unavailable", { status: 503 });
  }
  const work = processReceipt(client, id).catch(() => {
    // A worker/runtime failure leaves the receipt claimable after its lease.
    log.event("webhook.deferred", "failure", {
      job_id: id,
      provider: "whatsapp",
    });
  });
  await waitUntil(work);
  log.event("webhook.ack", "accepted", {
    job_id: id,
    provider: "whatsapp",
    deferred: hasWaitUntil(),
  });
  return new Response();
}
