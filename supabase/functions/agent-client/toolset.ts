import type { LocalMCPToolConfig } from "../_shared/supabase.ts";
import { z } from "zod";
import type { AgentTool } from "./agent_tool.ts";
import type { AgentRowWithExtra, RequestContext } from "./protocols/base.ts";
import { describeRemoteTool, initMCP, type MCPServer } from "./tools/mcp.ts";
import { Toolbox } from "./tools/index.ts";
import { EscalateToHumanTool } from "./tools/escalate.ts";

/** Connects the agent's MCP servers not connected yet. */
export async function initMCPServers(
  agent: AgentRowWithExtra,
  mcpServers: Map<string, MCPServer>,
  context: RequestContext,
): Promise<void> {
  const mcpServersToInit = agent.extra.tools?.filter(
    (tool) =>
      tool.provider === "local" &&
      tool.type === "mcp" &&
      !mcpServers.has(tool.label),
  ) || [];

  const mcpServersAux = await Promise.all(
    mcpServersToInit.map((tool) =>
      initMCP(tool as LocalMCPToolConfig, context)
    ),
  );

  mcpServersAux.forEach((mcp) => {
    mcpServers.set(mcp.label, mcp);
  });
}

/** The tools offered to the model in one iteration. */
export function buildAgentTools(
  agent: AgentRowWithExtra,
  mcpServers: Map<string, MCPServer>,
  context?: RequestContext,
): AgentTool[] {
  /**
   * Tools to be passed the agent are gruped in two main categories:
   * 1. Local tools
   * 2. External tools
   *
   * Local tools need to be passed to the agent with their input schema.
   * External tools do not require more than their tool config as it comes.
   *
   * We have the following tool types:
   * - `ToolInfo` to tag tool use/result messages with basic tool info (specially `label` and `name`).
   * - `ToolConfig` for agents to declare their tools (`label`, `name` might be unknown for MCP tools and others).
   * - `ToolDefinition`, which as its name suggests, defines the tool (`label` is unknown at definition, only `name`).
   * - `AgentTool`, the combination of config and definition, to be passed to the agent.
   */
  const tools: AgentTool[] = [];

  // H3: handing the conversation to a person only means something where
  // there IS a contact on the other side — not in team chat, where the peer
  // is a colleague already. On per default, because an organization that
  // sells cash on delivery needs it before it knows it does; off per agent
  // with extra.can_escalate = false.
  if (
    context && context.conversation.service !== "local" &&
    agent.extra.can_escalate !== false
  ) {
    tools.push(EscalateToHumanTool as unknown as AgentTool);
  }

  for (const toolConfig of agent.extra.tools || []) {
    if (toolConfig.provider !== "local") {
      continue;
    }

    switch (toolConfig.type) {
      case "function": {
        const unlabeledTool = Toolbox.function.find(
          (t) => t.name === toolConfig.name,
        );

        if (!unlabeledTool) {
          throw new Error(`Tool ${toolConfig.name} not found.`);
        }

        tools.push(unlabeledTool);

        break;
      }
      case "mcp": {
        const unlabeledTools = mcpServers.get(toolConfig.label)!.tools;

        for (const unlabeledTool of unlabeledTools) {
          const labeledTool = {
            provider: toolConfig.provider,
            type: toolConfig.type,
            label: toolConfig.label,
            name: unlabeledTool.name,
            // F08: remote text, bounded and attributed.
            description: describeRemoteTool(
              toolConfig.label,
              unlabeledTool.description,
            ),
            inputSchema: unlabeledTool
              .inputSchema as z.core.JSONSchema.JSONSchema,
            outputSchema: unlabeledTool.outputSchema as
              | z.core.JSONSchema.JSONSchema
              | undefined,
            config: toolConfig.config,
          };

          tools.push(labeledTool);
        }

        break;
      }
      case "http":
      case "sql": {
        const unlabeledTools = Toolbox[toolConfig.type];

        for (const unlabeledTool of unlabeledTools) {
          const labeledTool = {
            ...unlabeledTool,
            label: toolConfig.label,
            config: toolConfig.config,
          };

          tools.push(labeledTool);
        }

        break;
      }
    }
  }

  return tools;
}
