// H2 — the two decisions both protocols have to make the same way: who said
// each message, and what the system prompt is made of.
//
// They lived twice, once per protocol, and drifted the moment either changed.
import dayjs from "dayjs";
import utc from "dayjs/plugin/utc";
import { inspect } from "node:util";
import type { MessageRow } from "../../_shared/supabase.ts";
import { attentionContext } from "../../_shared/attention.ts";
import { businessProfileBlock } from "../../_shared/business_profile.ts";
import type { RequestContext } from "./base.ts";
dayjs.extend(utc);

/**
 * AUTHORSHIP IS A PROPERTY OF THE SPACE, NOT OF THE AGENT.
 *
 * On an external service the conversation has two sides: the contact, who
 * always carries a `sender_address`, and us — everything else, whether an AI
 * wrote it or a person of the organization typed it by hand. The model is one
 * voice of that side (D3), so it has to read the company's own words as its
 * own.
 *
 * The rule used to be `row.agent_id === agent.id`, which answers a narrower
 * question: "did THIS agent write it". A human's reply then arrived as
 * `user` — the model read a colleague's promise as the customer's request and
 * answered it, or contradicted it.
 *
 * `local` keeps that rule, and must: there the peer IS a colleague, so
 * everything this agent did not write is somebody talking TO it.
 */
export function historyRole(
  context: RequestContext,
  row: MessageRow,
): "assistant" | "user" {
  if (context.conversation.service === "local") {
    return row.agent_id === context.agent.id ? "assistant" : "user";
  }

  return row.sender_address === null ? "assistant" : "user";
}

/**
 * THE ORDER OF THE SYSTEM PROMPT, fixed for the whole agents spec:
 *
 *   1. brand voice          the organization's tone (H2)
 *   2. business profile     what it sells, ships, charges (T1)
 *   3. agent instructions   the agent's own job
 *   4. guardrails           what a template locks (T6)
 *   5. runtime context      date, contact, business hours (H4), origin (R2)
 *
 * Guardrails (4) do not exist yet. The order does, so adding them later moves
 * nothing that is already written — which is what T1 just spent: the profile
 * went into slot 2 and no other block changed.
 */
export function buildSystemPrompt(context: RequestContext): string {
  const blocks: string[] = [];

  const brandVoice = context.organization.extra?.brand_voice?.trim();

  if (brandVoice) {
    blocks.push(brandVoice);
  }

  // 2. What the business sells, ships and charges (T1). Before the agent's
  // own instructions, so a template's block can say "offer what the business
  // sells" over a profile that is already on the page.
  const businessProfile = businessProfileBlock(context.organization.extra);

  if (businessProfile) {
    blocks.push(businessProfile);
  }

  if (context.agent.extra.instructions) {
    blocks.push(context.agent.extra.instructions);
  }

  // 4. Guardrails (T6).

  blocks.push(inspect(runtimeContext(context), {
    compact: false,
    depth: Infinity,
    colors: false,
  }));

  return blocks.join("\n\n");
}

/** The facts that change between one invocation and the next. */
function runtimeContext(context: RequestContext) {
  // H4: whether the team is reachable right now, and when it is next — so an
  // agent handing a conversation over after hours says when somebody will
  // answer instead of promising one immediately. Absent for an organization
  // with no schedule, which is reachable at any hour.
  const attention = attentionContext(context.organization.extra);

  return {
    now: dayjs.utc().format("dddd, YYYY-MM-DD HH:mm [UTC]"),
    ...(attention && { attention }),
    user: {
      name: context.contact?.name,
      // The '+address' spelling is a phone-space thing; a local DM's address
      // is a roster of agent ids, not something to dial.
      phone: context.conversation.service !== "local" &&
          context.conversation.address
        ? "+" + context.conversation.address
        : undefined,
    },
  };
}
