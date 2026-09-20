import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../_shared/types/database_types.ts";
import * as log from "../_shared/logger.ts";
import {
  type ConversationRow,
  type DataPart,
  type InternalMessage,
  isToolTrace,
  type OutgoingMessage,
  type Part,
  type ToolInfo,
} from "../_shared/supabase.ts";
import Ajv2020 from "ajv";
import { getFileMetadata } from "../_shared/media.ts";
import type { AgentTool } from "./agent_tool.ts";
import type {
  AgentRowWithExtra,
  RequestContext,
  ResponseContext,
} from "./protocols/base.ts";
import { callTool, type MCPServer } from "./tools/mcp.ts";

/**
 * Runs the local tool uses in a model response and appends their results to
 * `response.messages`. Returns the tool uses found: none ends the loop.
 */
export async function runToolUses({
  response,
  tools,
  mcpServers,
  context,
  client,
  conv,
  agent,
  organization_id,
}: {
  response: ResponseContext & {
    messages: NonNullable<ResponseContext["messages"]>;
  };
  tools: AgentTool[];
  mcpServers: Map<string, MCPServer>;
  context: RequestContext;
  client: SupabaseClient<Database>;
  conv: ConversationRow;
  agent: AgentRowWithExtra;
  organization_id: string;
}) {
  // TOOL USES AND RESULTS

  // A tool trace is one carrying `content.tool` — the same thing the
  // database reads to call the row internal.
  const toolUses = response.messages.filter(
    (m) =>
      isToolTrace(m) &&
      m.content.tool.provider === "local" &&
      m.content.type === "text",
  ) || [];

  for (const row of toolUses) {
    // `content.tool` is the tag, not `direction`: the database derives the
    // latter from the former, and a tool trace is the only content that
    // carries it.
    let content = row.content as InternalMessage;
    const toolInfo = content.tool;

    // Only needed to please the TypeScript compiler
    if (
      !toolInfo ||
      toolInfo.provider !== "local" ||
      content.type !== "text"
    ) {
      continue;
    }

    /**
     * # Tool uses and results within parallel tool use
     *
     * Chat Completions API produces a single message with several tool choices.
     * It expects tool results as single messages.
     *
     * On the other hand, Responses API and Messages API also produce a single with several tool uses.
     * But on the contrary, they expect tool results as a single message.
     *
     * Here, the adopted policy is to adhere to the WhatsApp API, this is one message per part.
     * A tool use/result is considered a part.
     */

    let parts: (Part & ToolInfo)[] = [];

    const agentTool = tools.find(
      (t) =>
        t.provider === toolInfo.provider &&
        t.type === toolInfo.type &&
        ("label" in toolInfo ? t.label === toolInfo.label : true) &&
        t.name === toolInfo.name,
    );

    try {
      if (!agentTool) {
        throw new Error(
          `Tool ${toolInfo.name} not found between available tools.`,
        );
      }

      const ajv = new Ajv2020();
      // Strip $schema since MCP SDK (via Zod) produces draft-07 schemas,
      // but Ajv is imported as the 2020-12 build and rejects unknown drafts.
      // deno-lint-ignore no-explicit-any
      const { $schema: _, ...schema } = agentTool.inputSchema as any;

      const args = JSON.parse(content.text);

      // When JSON parsing is done, the message is converted to a data part.
      content = {
        version: "1",
        internal: true,
        task: content.task,
        tool: toolInfo,
        type: "data",
        kind: "data",
        data: args,
      };

      row.content = content;

      const valid = ajv.validate(schema, args);

      if (!valid) {
        throw new Error(
          `Tool input validation failed: ${JSON.stringify(ajv.errors)}`,
        );
      }

      switch (toolInfo.type) {
        case "custom":
        case "function": {
          // The wider signature of the special tools (config, context,
          // client), so a function tool that needs the conversation — H3's
          // escalate_to_human — can have it. The ones that do not, like the
          // calculator, ignore the extra arguments.
          const result = await agentTool.implementation(
            args,
            agentTool.config,
            context,
            client,
          );

          parts = [
            {
              tool: {
                ...toolInfo,
                event: "result" as const,
              },
              type: "data",
              kind: "data",
              data: result,
            },
          ];

          break;
        }
        case "mcp": {
          const mcp = mcpServers.get(agentTool.label!);

          if (!mcp) {
            throw new Error(`MCP server ${agentTool.label} not found.`);
          }

          parts = await callTool(mcp, content, context, client);

          break;
        }
        case "http":
        case "sql": {
          const result = await agentTool.implementation(
            args,
            agentTool.config,
            context,
            client,
          );

          const part: DataPart & ToolInfo = {
            tool: {
              ...toolInfo,
              event: "result" as const,
            },
            type: "data",
            kind: "data",
            data: result,
          };

          parts = [part];

          if (result.file_uri) {
            part.artifacts = [
              {
                type: "file",
                kind: "document",
                file: await getFileMetadata(client, result.file_uri),
              },
            ];
          }

          break;
        }
      }
    } catch (error) {
      const errorMessage = (error as Error).message || String(error);

      log.warn("Tool error", { tool: toolInfo, error });

      parts = [
        {
          tool: {
            ...toolInfo,
            is_error: true,
            event: "result" as const,
          },
          type: "text",
          kind: "text",
          text: errorMessage,
        },
      ];
    }

    // TODO: Mutating the response object is not the most recommended way to do this
    // but it will be improved soon.
    const taskId = content.task?.id || crypto.randomUUID();

    for (const part of parts) {
      const message = part.type === "file"
        ? {
          organization_id,
          service: conv.service,
          organization_address: conv.organization_address,
          conversation_address: conv.address,
          agent_id: agent.id,
          content: {
            version: "1" as const,
            task: { id: taskId },
            ...part,
          } as OutgoingMessage,
        }
        : {
          organization_id,
          service: conv.service,
          organization_address: conv.organization_address,
          conversation_address: conv.address,
          agent_id: agent.id,
          content: {
            version: "1" as const,
            internal: true as const,
            task: { id: taskId },
            ...part,
          } as InternalMessage,
        };

      response.messages.push(message);
    }
  }

  return toolUses;
}
