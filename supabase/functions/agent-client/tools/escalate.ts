// H3 — handing the conversation to a person.
//
// Without this the agent's only options are to keep trying or to go silent,
// and a store selling cash on delivery has conversations no bot should be
// holding: a complaint, a payment gone wrong, somebody asking for a human.
//
// Calling it does two things and neither is a message: the conversation stops
// being the AI's (so `selectAgent` stops answering it) and starts waiting for
// a person, with the reason recorded in the assignment note H1 writes.
// Telling the contact is the agent's own job, BEFORE calling — the tool
// description says so, because after the call it has no turn left.
import { z } from "zod";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { RequestContext } from "../protocols/base.ts";
import type { ToolDefinition } from "./base.ts";
import * as log from "../../_shared/logger.ts";

/**
 * Closed on purpose: M1 counts escalations by category to say what the AI
 * cannot handle, and a free-text field would make that ungroupable. `otro`
 * is the escape hatch, with `reason` carrying the specifics.
 */
export const ESCALATION_CATEGORIES = [
  "reclamo",
  "pedido_fuera_de_alcance",
  "pide_persona",
  "pago",
  "envio",
  "cambio_devolucion",
  "otro",
] as const;

const EscalateInputSchema = z.object({
  category: z.enum(ESCALATION_CATEGORIES).describe(
    "Motivo, en una de estas categorías cerradas.",
  ),
  reason: z.string().describe(
    "Qué pasó, en una frase, para quien tome la conversación. " +
      "No incluyas datos que el cliente no haya dado.",
  ),
});

const EscalateOutputSchema = z.object({
  escalated: z.boolean(),
});

export const ESCALATE_TOOL_NAME = "escalate_to_human";

export async function escalateToHumanImplementation(
  input: z.infer<typeof EscalateInputSchema>,
  _config: unknown,
  context: RequestContext,
  client: SupabaseClient,
): Promise<z.infer<typeof EscalateOutputSchema>> {
  const { data, error } = await client.rpc("set_conversation_assignment", {
    p_conversation_id: context.conversation.id,
    p_agent_id: null,
    p_awaiting_human: true,
    p_actor_agent_id: context.agent.id,
    p_reason: {
      cause: "escalation",
      category: input.category,
      reason: input.reason,
    },
  });

  if (error) {
    // The model gets the failure as a tool result and can try again or keep
    // talking; silently reporting success would leave the contact waiting
    // for a person nobody was told about.
    log.error("Failed to escalate the conversation", {
      conversation_id: context.conversation.id,
      category: input.category,
      error: error.message,
    });

    throw new Error("No se pudo derivar la conversación.");
  }

  // Keep the handler's own view of the conversation in step with what we
  // just did, so its "did somebody take this from us?" check (assignment.ts)
  // reads this as ours and not as a stranger's, and lets the goodbye of this
  // same turn be stored. The row the gate returns, not a timestamp of our
  // own: that check compares values, and this process's clock is not the
  // database's.
  // A SQL composite that is NULL arrives as an object with every field null
  // (not as JSON null), so `id` is what says a row came back at all.
  const row = (Array.isArray(data) ? data[0] : data) as {
    id: string | null;
    assigned_agent_id: string | null;
    awaiting_human_since: string | null;
  } | null;

  if (row?.id) {
    context.conversation.assigned_agent_id = row.assigned_agent_id;
    context.conversation.awaiting_human_since = row.awaiting_human_since;
  } else {
    const { data: current } = await client
      .from("conversations")
      .select("assigned_agent_id, awaiting_human_since")
      .eq("id", context.conversation.id)
      .maybeSingle();

    context.conversation.assigned_agent_id = current?.assigned_agent_id ?? null;
    context.conversation.awaiting_human_since = current?.awaiting_human_since ??
      null;
  }

  return { escalated: true };
}

export const EscalateToHumanTool: ToolDefinition<
  typeof EscalateInputSchema,
  typeof EscalateOutputSchema,
  // Takes no configuration; the wider signature is what gives it the
  // conversation and the database client.
  Record<string, never>
> = {
  provider: "local",
  type: "function",
  name: ESCALATE_TOOL_NAME,
  description:
    "Entrega la conversación a una persona del equipo cuando no puedas " +
    "resolverla vos: reclamos, problemas de pago o de envío, cambios y " +
    "devoluciones, o si el cliente pide hablar con alguien. " +
    "IMPORTANTE: después de llamarla te queda UNA sola respuesta: usala " +
    "para despedirte y avisarle al cliente que lo va a atender una persona " +
    "del equipo. Después de eso la conversación deja de ser tuya y no " +
    "podés escribirle más.",
  inputSchema: z.toJSONSchema(EscalateInputSchema),
  outputSchema: z.toJSONSchema(EscalateOutputSchema),
  implementation: escalateToHumanImplementation,
};
