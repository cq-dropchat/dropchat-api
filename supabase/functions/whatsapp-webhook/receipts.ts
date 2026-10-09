import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database, MetaWebhookPayload } from "../_shared/supabase.ts";
import * as log from "../_shared/logger.ts";
import { processPayload } from "./process.ts";

export async function receive(
  client: SupabaseClient<Database>,
  body: string,
  payload: MetaWebhookPayload,
): Promise<string> {
  const digest = Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(body)),
    ),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
  await client.from("webhook_receipts").upsert({
    digest,
    payload:
      payload as unknown as Database["public"]["Tables"]["webhook_receipts"][
        "Insert"
      ]["payload"],
    correlation_id: log.currentRequestId(),
  }, { onConflict: "digest", ignoreDuplicates: true }).throwOnError();
  const { data } = await client.from("webhook_receipts").select("id").eq(
    "digest",
    digest,
  ).single().throwOnError();
  log.event("webhook.queued", "success", {
    job_id: data.id,
    provider: "whatsapp",
  });
  return data.id;
}
export async function processReceipt(
  client: SupabaseClient<Database>,
  id: string,
  process = processPayload,
): Promise<void> {
  const { data } = await client.rpc("claim_webhook_receipt", { _id: id })
    .throwOnError();
  const receipt = data[0];
  if (!receipt) return;
  const started = performance.now();
  log.event("webhook.processing", "started", {
    job_id: id,
    attempt: receipt.attempts,
    provider: "whatsapp",
  });
  try {
    await log.withJobLogging(
      id,
      receipt.attempts,
      () => process(client, receipt.payload as unknown as MetaWebhookPayload),
    );
    const { data: completed } = await client.rpc("complete_webhook_receipt", {
      _id: id,
      _lease_token: receipt.lease_token!,
      _success: true,
    }).throwOnError();
    if (!completed) {
      log.event("webhook.lease_lost", "failure", {
        job_id: id,
        attempt: receipt.attempts,
        error_class: "stale_lease",
      });
      return;
    }
    log.event("webhook.persisted", "success", {
      job_id: id,
      attempt: receipt.attempts,
      duration_ms: performance.now() - started,
      provider: "whatsapp",
    });
  } catch (error) {
    const errorClass = error && typeof error === "object" && "code" in error
      ? String(error.code)
      : error instanceof Error
      ? error.name
      : "unknown";
    await client.rpc("complete_webhook_receipt", {
      _id: id,
      _lease_token: receipt.lease_token!,
      _success: false,
      _error_class: errorClass,
    }).throwOnError();
    log.event("webhook.persisted", "failure", {
      job_id: id,
      attempt: receipt.attempts,
      error_class: errorClass,
      duration_ms: performance.now() - started,
      provider: "whatsapp",
    });
  }
}
