import * as log from "../_shared/logger.ts";
import type {
  AgentProtocolHandler,
  ResponseContext,
} from "./protocols/base.ts";
import { AgentOutputError } from "./protocols/output.ts";

/** Retry unusable output once, before any tool execution or message writes. */
export async function requestAgentResponse<Request, Response>(
  handler: AgentProtocolHandler<Request, Response>,
  beforeRequest: () => Promise<boolean>,
  details: { conversation_id: string; message_id: string; agent_id: string },
): Promise<ResponseContext | null> {
  const request = await handler.prepareRequest();
  for (let attempt = 1; attempt <= 2; attempt++) {
    // Recovery must not speak over a newer customer message or a human takeover.
    if (!(await beforeRequest())) return null;
    try {
      const output = await handler.sendRequest(request);
      const response = await handler.processResponse(output);
      if (!response.messages?.length && response.skipResponse !== true) {
        throw new AgentOutputError("empty_response");
      }
      if (response.skipResponse) {
        log.info("Agent explicitly skipped responding", details);
      } else if (attempt > 1) {
        log.info("Agent output recovered", { ...details, attempt });
      }
      return response;
    } catch (error) {
      if (
        !(error instanceof AgentOutputError) || !error.retryable ||
        attempt === 2
      ) {
        throw error;
      }
      log.warn("Retrying unusable agent output", {
        ...details,
        attempt,
        reason: error.reason,
      });
    }
  }
  throw new AgentOutputError("empty_response");
}
