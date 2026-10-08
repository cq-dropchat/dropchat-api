/** A provider answered, but its output cannot safely be sent or executed. */
export class AgentOutputError extends Error {
  constructor(public reason: string, public retryable = true) {
    super(`Invalid agent output: ${reason}`);
    this.name = "AgentOutputError";
  }
}

type RespondMessage =
  | { type: "text"; text: string }
  | { type: "file"; uri: string; name?: string; text?: string };

/** Validate the entire batch before sending messages or resolving files. */
export function parseRespondArguments(input: string): RespondMessage[] {
  let args;
  try {
    args = JSON.parse(input);
  } catch {
    throw new AgentOutputError("respond_invalid_json");
  }
  if (!args || !Array.isArray(args.messages)) {
    throw new AgentOutputError("respond_missing_messages");
  }
  for (const msg of args.messages) {
    if (
      !msg ||
      (msg.type !== "text" && msg.type !== "file") ||
      (msg.type === "text" &&
        (typeof msg.text !== "string" || !msg.text.trim())) ||
      (msg.type === "file" &&
        (typeof msg.uri !== "string" || !msg.uri.trim() ||
          (msg.name !== undefined && typeof msg.name !== "string") ||
          (msg.text !== undefined && typeof msg.text !== "string")))
    ) {
      throw new AgentOutputError("respond_invalid_message");
    }
  }
  return args.messages;
}
