import type { AgentProtocolHandler, RequestContext } from "./base.ts";
import { ChatCompletionsHandler } from "./chat-completions.ts";
import { ResponsesHandler } from "./responses.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { AgentTool } from "../agent_tool.ts";
import { resolveProtocol } from "../../_shared/model_resolution.ts";

export class ProtocolFactory {
  static getHandler(
    tools: AgentTool[],
    context: RequestContext,
    client: SupabaseClient,
  ): AgentProtocolHandler {
    // T2: the tier decides, when there is one. It carries the protocol
    // because the provider it names may not speak both.
    const protocol = resolveProtocol(context.agent.extra, context.tier);

    switch (protocol) {
      case "chat_completions":
        return new ChatCompletionsHandler(tools, context, client);
      case "responses":
        return new ResponsesHandler(tools, context, client);
      default:
        throw new Error(`Unsupported protocol: ${protocol}`);
    }
  }
}
