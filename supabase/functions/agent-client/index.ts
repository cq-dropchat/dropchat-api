// The AI agent of a conversation: selects the agent, waits for its turn,
// then runs the model and its tools until it answers. F29: split from one
// 1,107-line file into
//   selection.ts      AI DM detection, contact, agent selection, peer predicate
//   conversation.ts   context window, session restart, newer peer messages
//   typing.ts         typing indicator and turn keep-alive
//   preprocessing.ts  waiting for media preprocessing
//   toolset.ts        MCP servers and the tools offered per iteration
//   tool_uses.ts      running tool uses into result rows
//   store.ts          storing an iteration; the record-only error row
import { isServiceToken } from "../_shared/service_auth.ts";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import * as log from "../_shared/logger.ts";
import { withRequestLogging } from "../_shared/logger.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { revealAgent } from "../_shared/secrets.ts";
import {
  type AgentRow,
  createUnsecureClient,
  type MessageInsert,
  type MessageRow,
  type TextPart,
  type WebhookPayload,
} from "../_shared/supabase.ts";
import {
  beginAgentTurn,
  releaseAgentTurn,
  renewAgentTurn,
  waitForAgentTurn,
} from "../_shared/agent_turns.ts";
import { ProtocolFactory } from "./protocols/index.ts";
import type { AgentRowWithExtra, ResponseContext } from "./protocols/base.ts";
import type { MCPServer } from "./tools/mcp.ts";
import { sanitizeLabel } from "./agent_tool.ts";
import {
  findNewerPeerMessage,
  getNewestIncomingMessage,
  loadRecentMessages,
  restartSessionIfAsked,
  spokenByUs,
} from "./conversation.ts";
import {
  findDmAI,
  loadContact,
  peerPredicate,
  selectAgent,
  TEAM_CHAT_SERVICES,
} from "./selection.ts";
import {
  assignConversation,
  clearAssignmentOnRestart,
  loadAssignedAgent,
  previousContactMessageAt,
  takenFromUs,
} from "./assignment.ts";
import { startTyping } from "./typing.ts";
import { waitForPendingPreprocessing } from "./preprocessing.ts";
import { buildAgentTools, initMCPServers } from "./toolset.ts";
import { runToolUses } from "./tool_uses.ts";
import { agentErrorMessages, storeIterationMessages } from "./store.ts";

export type { AgentTool } from "./agent_tool.ts";

const RESPONSE_DELAY_SECS = 3; // 3 seconds

export async function handler(req: Request): Promise<Response> {
  const authHeader = req.headers.get("Authorization");
  const token = authHeader?.replace("Bearer ", "");

  if (!isServiceToken(token)) {
    return new Response("Unauthorized", { status: 401 });
  }

  const client = createUnsecureClient();

  const incoming = ((await req.json()) as WebhookPayload<MessageRow>).record!;

  // RETRIEVE CONVERSATION + ORGANIZATION + LIVE AI AGENTS (one-hop join)
  //
  // F23: only the agents that can answer — no user_id, not retired. The
  // embed used to carry every member row and retired AI with its `extra`,
  // and all of their secrets were decrypted, on every invocation.
  //
  // H1: the relationship is named. organizations.entry_agent_id gave
  // organizations a SECOND path to agents, and PostgREST refuses an ambiguous
  // embed outright ("more than one relationship was found") — the query threw
  // and no contact got an answer until this said which one it means.

  const { data: conv } = await client
    .from("conversations")
    .select(`
      *,
      organizations (*, agents!agents_organization_id_fkey (*))
    `)
    .eq("id", incoming.conversation_id)
    .is("organizations.agents.user_id", null)
    .is("organizations.agents.deleted_at", null)
    .single()
    .throwOnError();

  if (!conv.extra) {
    conv.extra = {};
  }

  const {
    organizations: org,
    ...conversation
  } = conv;

  log.info("Agent client context", {
    conversation_id: conv.id,
    has_org: !!org,
  });

  const organization_id = org.id;

  if (!org.extra) {
    org.extra = {};
  }

  // F02: agents.extra carries masks; the LLM key and tool credentials come
  // from public.secrets — revealed below for the selected agent only (F23).
  const { agents, ...organization } = org;

  // The embed's generated type went to "one row or null" when H1 added
  // conversations.assigned_agent_id → agents: PostgREST sees a second path
  // between the two tables. The query is still the to-many one (it filters
  // `organizations.agents.user_id`), so the shape is normalized here, once.
  const aiAgents =
    (Array.isArray(agents) ? agents : agents ? [agents] : []) as AgentRow[];

  // AI DM DETECTION (local only)
  //
  // A local direct's address IS its roster (two agent ids, sorted,
  // ':'-joined), and direct rosters are immutable identity — so the address
  // alone answers "is this a DM with an AI?". The rule: exactly ONE live AI
  // in the roster, and the author is the other slot. Requiring exactly one
  // also refuses an AI–AI room (a service-role insert can mint one), which
  // would otherwise be two armed repliers ping-ponging with an LLM bill
  // attached. This re-verifies what handle_local_message_to_agent already
  // checked: the trigger is the doorbell, this is the authority.

  const dmAI = findDmAI(conv, aiAgents, incoming);

  // NO AI IN TEAM CHAT — except a DM with one.
  //
  // Team chat is where colleagues talk to each other, and `local` is only the
  // half we host: a mirrored Slack workspace is the same conversation with
  // someone else's servers in the middle. An AI agent answering a ROOM would
  // need trigger rules this codebase does not have — who it answers, when,
  // and without replying to every message. A DM with the AI has no such
  // question: both slots of the address are known, one is the AI, and every
  // peer message is addressed to it.

  if (TEAM_CHAT_SERVICES.has(conv.service) && !dmAI) {
    log.info(`Conversation ${conv.id} is team chat. Skipping response.`);

    return new Response("ok", { headers: corsHeaders });
  }

  // RETRIEVE CONTACT (external services only)
  //
  // The conversation's address is a soft reference (no FK, so no PostgREST
  // embed): the contact comes from its own query. On a direct chat the
  // conversation's address IS the contact's address; a group address simply
  // matches no contacts_addresses row and the contact stays null.
  //
  // A local roster would match nothing either — the peer is a colleague, not
  // a contact — so the DM path skips the query and shapes the author's agent
  // row like a contact instead: the protocol handlers only want a name.

  const contact = await loadContact(client, conv, incoming);

  // AGENT SELECTION
  //
  // External: the oldest active AI agent in the organization — an AI agent
  // being one that is nobody's membership (no user_id) and has not been
  // retired (deleted_at). There is no per-conversation override: nothing can
  // write one, since members hold no UPDATE on conversations outside `local`.
  //
  // Local DM: there is nothing to select — the address names the agent.
  //
  // Selected before the delay because the delay is the agent's own.

  // H1: the agent a conversation is assigned to may be a human or a retired
  // AI, and neither is in the AI-only embed above — so it is resolved here,
  // and only when there is an assignment the embed did not already carry.
  const assigned = await loadAssignedAgent(client, conv, aiAgents);

  const selection = selectAgent(
    conv,
    assigned ? [...aiAgents, assigned] : aiAgents,
    dmAI,
    organization,
    await previousContactMessageAt(client, conv, incoming),
  );

  // Persisted before the delay, so the conversation has an owner even if this
  // invocation ends up superseded — and conditionally, so a concurrent
  // invocation's decision is not overwritten.
  let ours = true;

  if (selection.assign) {
    ours = await assignConversation(
      client,
      // `conversation` and not `conv`: the context (and so the escalation
      // tool) holds this object, and the assignment checks below compare the
      // database against it. Two copies would read each other's writes as a
      // stranger's.
      conversation,
      selection.assign.agent_id,
      selection.assign.cause,
      selection.agent?.id ?? null,
    );
  }

  if (!ours) {
    // Another invocation won the routing race and holds the conversation; it
    // is the one that answers.
    log.info(
      `Conversation ${conv.id} was assigned by another invocation. Skipping response.`,
    );

    return new Response("ok", { headers: corsHeaders });
  }

  const agent = selection.agent && await revealAgent(client, selection.agent);

  const fromPeer = peerPredicate(conv, dmAI);

  // WAIT FOR A NEWER MESSAGE
  //
  // F16: the debounce lives in public.agent_turns. Registering here, before
  // the delay, makes this message the conversation's latest unless a newer
  // one already registered; only the latest message's invocation can claim
  // the turn below.

  await beginAgentTurn(client, incoming);

  const delay = (agent?.extra?.response_delay_seconds ?? RESPONSE_DELAY_SECS) *
    1000;

  if (delay > 0) {
    log.info(`Waiting ${delay}ms before processing the message...`);

    await new Promise((resolve) => setTimeout(resolve, delay));
  }

  // CLAIM THE TURN
  //
  // One invocation answers per conversation at a time. A newer message
  // exits here; a duplicate invocation of an answered message too; and a
  // message that lands while the previous one is being answered waits, so
  // it is answered with that reply already in the history (the holder
  // yields before its next LLM call once it sees it was superseded).

  const claim = await waitForAgentTurn(client, incoming);

  if (claim !== "claimed") {
    const details = { conversation_id: conv.id, message_id: incoming.id };
    if (claim === "timeout") {
      log.warn(
        "Timed out waiting for the agent turn. Skipping response.",
        details,
      );
    } else {
      log.info(`Agent turn ${claim}. Skipping response.`, details);
    }

    return new Response("ok", { headers: corsHeaders });
  }

  // Everything below holds the turn; the finally releases it on every exit.
  // `handled` marks the message answered, so a duplicate invocation of it
  // does not answer again.
  let handled = false;
  let typingInterval: ReturnType<typeof setInterval> | undefined;

  try {
    // RETRIEVE MESSAGES

    const messages = await loadRecentMessages(client, incoming);

    // CHECK IF THERE IS A NEWER MESSAGE
    const newestMessage = getNewestIncomingMessage(
      incoming,
      messages,
      fromPeer,
    );

    if (newestMessage.id !== incoming.id) {
      // Then the newest message is not the incoming one that triggered this edge function.
      log.info(
        `Newer message ${newestMessage.id} found for conversation ${conv.id}. Skipping response.`,
      );

      return new Response("ok", { headers: corsHeaders });
    }

    // SESSION RESTART if /new is found — USEFUL FOR WHATSAPP TESTING

    const messagesBeforeRestart = messages.length;

    await restartSessionIfAsked(client, conv, incoming, messages, fromPeer);

    // H1: `/new` resets the conversation's memory, and who answers it is part
    // of that — otherwise a restart would keep the human who took it, or an
    // agent chosen for a conversation that no longer has a history.
    await clearAssignmentOnRestart(
      client,
      conv,
      messages,
      messagesBeforeRestart,
    );

    log.info("Contact request", messages.at(-1)?.content);

    // The agent was chosen before the delay, above.

    if (!agent) {
      log.info(
        `No active AI agents found for conversation ${conv.id}. Skipping response.`,
      );
      return new Response("ok", { headers: corsHeaders });
    }

    // WELCOME MESSAGE
    //
    // The agent's, not the organization's — so it needs an agent; without
    // one, nobody greets. Still ahead of asking
    // the agent anything: it replaces the first answer rather than preceding it.
    //
    // Not in a DM: the member opened it, and the first word is theirs.

    if (
      conv.service !== "local" &&
      agent.extra.welcome_message &&
      !messages.some(spokenByUs)
    ) {
      const outgoing: MessageInsert = {
        organization_id: conv.organization_id,
        conversation_id: conv.id,
        service: conv.service,
        organization_address: conv.organization_address,
        conversation_address: conv.address,
        agent_id: agent.id,
        content: {
          version: "1",
          type: "text",
          kind: "text",
          text: agent.extra.welcome_message,
        },
      };

      log.info("Welcome message", (outgoing.content as TextPart).text);

      await client
        .from("messages")
        .insert(outgoing)
        .throwOnError();

      handled = true;

      return new Response("ok", { headers: corsHeaders });
    }

    //---------------------------------------------------------------------------
    // Up to this point all checks passed. We can proceed with the response.
    //---------------------------------------------------------------------------

    // TYPING INDICATOR

    typingInterval = startTyping(client, conv, agent, incoming);

    // CONTEXT

    if (!agent.extra) {
      agent.extra = {};
    }

    const context = {
      organization,
      conversation,
      messages,
      contact,
      agent: agent as AgentRowWithExtra,
    };

    if (agent.extra.tools) {
      for (const tool of agent.extra.tools) {
        if ("label" in tool) {
          tool.label = sanitizeLabel(tool.label);
        }
      }
    }

    // REQUEST LOOP

    /**
     * agent.extra.tools
     *   - function
     *   - mcp
     *   - gemini: google_search, code_execution, url_context
     *   - openai: mcp, web_search_preview, file_search, image_generation, code_interpreter, computer_use_preview
     *   - anthropic: mcp*, bash, code_execution, computer, str_replace_based_edit_tool, web_search
     *
     * context.tools -> tools + expanded mcp tools
     */

    const mcpServers: Map<string, MCPServer> = new Map();

    let iteration = 0;
    let iterationsAfterEscalation = 0;
    const max_iterations = 10;
    let shouldContinue = true;

    // Basic ReAct algorithm: stop if no tool uses are found.
    while (shouldContinue) {
      iteration++;

      let response: ResponseContext = {};

      try {
        if (iteration > max_iterations) {
          throw new Error("Max LLM iterations reached!");
        }

        // CHECK FOR PENDING PREPROCESSING

        await waitForPendingPreprocessing(client, org, messages);

        // STILL OUR TURN? (F16) Checked before every LLM call, so a message
        // that arrived meanwhile costs at most the call already in flight.

        const turn = await renewAgentTurn(client, incoming);

        if (turn !== "renewed") {
          log.info(
            `Agent turn ${turn} for conversation ${conv.id}. Skipping response.`,
            { conversation_id: conv.id, message_id: incoming.id },
          );

          return new Response("ok", { headers: corsHeaders });
        }

        // CHECK IF THERE IS A NEWER INCOMING MESSAGE (posterior to the incoming one)
        //
        // Covers a newer message whose own invocation has not registered yet.

        // STILL OURS? (H3) A person who answers by hand takes the
        // conversation (the implicit takeover), and an escalation hands it
        // away. Neither is a peer message, so agent_turns cannot see them:
        // without this the answer in flight would land on top of the human's.
        if (await takenFromUs(client, conversation)) {
          log.info(
            `Conversation ${conv.id} is no longer this agent's. Skipping response.`,
            { conversation_id: conv.id, message_id: incoming.id },
          );

          return new Response("ok", { headers: corsHeaders });
        }

        const new_message = await findNewerPeerMessage(
          client,
          conv,
          agent,
          incoming,
        );

        if (new_message) {
          log.info(
            `Newer message ${new_message.id} for conversation ${conv.id} found while processing tool use messages and/or waiting for pending preprocessing. Skipping response.`,
          );

          return new Response("ok", { headers: corsHeaders });
        }

        // MCP SERVERS INITIALIZATION
        // It is here because of multi-agents, which we are not using by the time being.

        await initMCPServers(agent, mcpServers, context);

        // CURRENT ITERATION TOOLS

        const tools = buildAgentTools(agent, mcpServers, context);

        // AGENT CLIENT REQUEST AND RESPONSE

        const handler = ProtocolFactory.getHandler(tools, context, client);

        const agentRequest = await handler.prepareRequest();

        const agentResponse = await handler.sendRequest(agentRequest);

        response = await handler.processResponse(agentResponse);

        if (!response.messages?.length) {
          response.messages = [];
        }

        // TOOL USES AND RESULTS

        const toolUses = await runToolUses({
          response: response as ResponseContext & { messages: MessageInsert[] },
          tools,
          mcpServers,
          context,
          client,
          conv,
          agent,
          organization_id,
        });

        if (!toolUses.length) {
          shouldContinue = false;
        }
      } catch (error) {
        shouldContinue = false;

        log.error("Error in agent client", error as Error);

        response.messages = agentErrorMessages(
          conv,
          organization_id,
          agent,
          error,
        );
      }

      // STORE CURRENT ITERATION MESSAGES
      //
      // H3: the same question again, because the LLM call takes seconds and
      // a person can answer inside them. What this agent itself did in this
      // turn — routing, an escalation — is already in `conv`, so it does not
      // read as somebody else.

      if (await takenFromUs(client, conversation)) {
        log.info(
          `Conversation ${conv.id} was taken while answering. Dropping the response.`,
          { conversation_id: conv.id, message_id: incoming.id },
        );

        return new Response("ok", { headers: corsHeaders });
      }

      if (!(await storeIterationMessages(client, conv, messages, response))) {
        shouldContinue = false;
      }

      // An escalation gives the agent ONE more iteration — its goodbye — and
      // then the turn is over: from there the conversation belongs to
      // whoever takes it.
      //
      // One and not zero because a `respond` call ends the round on its own
      // (the protocol returns its messages and drops any other tool call in
      // the same message), so an agent that escalated could not also say
      // goodbye. One and not "until it stops" because nothing else would
      // bound what it does after handing the conversation away.
      if (conversation.awaiting_human_since) {
        if (iterationsAfterEscalation >= 1) {
          shouldContinue = false;
        }

        iterationsAfterEscalation++;
      }
    }

    // STORE RESPONSE

    /*
  if (response?.conversation) {
    const { error } = await client
      .from("conversations")
      .update({
        extra: response.conversation.extra,
      })
      .eq("id", incoming.conversation_id)

    if (error) {
      log.error("Failed to update conversation extra field.", error);
    }
  }
  */

    handled = true;

    // The caller is pg_net, which discards the body — don't serialize the
    // whole conversation into it.
    return new Response("ok", { headers: corsHeaders });
  } finally {
    // Every exit — answered, superseded mid-loop, or thrown — stops the
    // keep-alive and drops the lease, so the next message is not left
    // waiting for it to lapse.
    clearInterval(typingInterval);
    await releaseAgentTurn(client, incoming, handled).catch((releaseError) =>
      log.warn("Failed to release the agent turn.", releaseError)
    );
  }
}

if (import.meta.main) {
  Deno.serve(withRequestLogging("agent-client", handler));
}
