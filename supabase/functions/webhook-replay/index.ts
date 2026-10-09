import { createUnsecureClient } from "../_shared/supabase.ts";
import { isServiceToken } from "../_shared/service_auth.ts";
import { withRequestLogging } from "../_shared/logger.ts";
import { processReceipt } from "../whatsapp-webhook/receipts.ts";
export async function handler(req: Request): Promise<Response> {
  if (
    !isServiceToken(
      req.headers.get("authorization")?.replace(/^Bearer /i, "") ?? "",
    )
  ) return new Response("Unauthorized", { status: 401 });
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  const { receipt_id } = await req.json();
  if (typeof receipt_id !== "string" || !/^[0-9a-f-]{36}$/i.test(receipt_id)) {
    return new Response("Invalid receipt", { status: 400 });
  }
  await processReceipt(createUnsecureClient(), receipt_id);
  return new Response();
}
if (import.meta.main) Deno.serve(withRequestLogging("webhook-replay", handler));
