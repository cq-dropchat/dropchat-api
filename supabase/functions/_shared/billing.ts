// F17. AI credits: reserve before the call, record after it, once.
//
// Before: check_limit(ai_credits, 0) let the last call through at any balance
// above the floor, so the balance went negative by that call's cost; and the
// ledger insert had no key, so a retried insert charged twice.
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "./types/database_types.ts";
import type { Json } from "./db_types.ts";

/** Output budget assumed when the agent sets no max_tokens. */
export const DEFAULT_MAX_OUTPUT_TOKENS = 4096;

/**
 * A deliberately generous token count for a request: ~4 characters per
 * token over its JSON. Overestimating only refuses a call a few cents early;
 * underestimating is what let balances go negative.
 */
export function estimateInputTokens(request: unknown): number {
  return Math.ceil((JSON.stringify(request ?? "")?.length ?? 0) / 4);
}

type Client = SupabaseClient<Database>;

export type CostRow = { pricing: Json; quantity: number };

/**
 * Refuses (PT402, "Insufficient balance") when the organization cannot
 * cover the call's upper-bound cost. Returns the estimate.
 */
export async function reserveAiCredits(
  client: Client,
  organizationId: string,
  costs: CostRow,
  inputTokens: number,
  maxOutputTokens: number | null | undefined,
): Promise<number> {
  const { data: estimate } = await client
    .schema("billing")
    .rpc("estimate_ai_cost", {
      _pricing: costs.pricing,
      _quantity: costs.quantity,
      _input_tokens: inputTokens,
      _max_output_tokens: maxOutputTokens ?? DEFAULT_MAX_OUTPUT_TOKENS,
    })
    .throwOnError();

  await client
    .schema("billing")
    .rpc("check_limit", {
      _organization_id: organizationId,
      _product_id: "ai_credits",
      _amount: estimate ?? 0,
    })
    .throwOnError();

  return estimate ?? 0;
}

export type AiConsumption = {
  organization_id: string;
  provider: string | null | undefined;
  model: string | null | undefined;
  /** The provider's response id: with provider, the idempotency key. */
  external_id: string | null | undefined;
  cost: number;
  billable: boolean;
  agent_id?: string | null;
  message_id?: string | null;
  metadata?: Json;
};

/** Writes the consumption once per provider response. */
export async function recordAiConsumption(
  client: Client,
  entry: AiConsumption,
): Promise<void> {
  await client
    .schema("billing")
    .from("ledger")
    .upsert(
      {
        organization_id: entry.organization_id,
        product_id: "ai_credits",
        type: "consumption",
        quantity: -entry.cost,
        agent_id: entry.agent_id ?? null,
        message_id: entry.message_id ?? null,
        provider: entry.provider ?? null,
        model: entry.model ?? null,
        external_id: entry.external_id ?? null,
        billable: entry.billable,
        metadata: entry.metadata ?? null,
      },
      { onConflict: "provider,external_id", ignoreDuplicates: true },
    )
    .throwOnError();
}
