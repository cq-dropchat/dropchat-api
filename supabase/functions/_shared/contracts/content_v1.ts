// F29: the root type of the published content contract.
import type {
  IncomingMessage,
  InternalMessage,
  OutgoingMessage,
} from "../types/message_types.ts";

/** `messages.content` for version "1": what any direction can store. */
export type MessageContentV1 =
  | IncomingMessage
  | OutgoingMessage
  | InternalMessage;
