// §5.2 — v0 message content → v1, for the one-off backfill of the rows that
// predate the v1 content schema (~46k in production when audited).
//
// A port of the UI's `toV1` (open-bsp-ui src/supabase/messages-v0.ts), checked
// case by case against it (_shared/__fixtures__/messages_v0/cases.json). It
// departs from it where the UI's version no longer holds:
//
// - Tool traces. The UI recognizes them by `direction === "internal"`, a
//   column dropped in 20260801210519_drop_direction_and_contact_address, so
//   today it turns a tool call into a `kind: "function"` data part and a tool
//   result into a plain text — which v1 readers would treat as spoken. Here
//   they are recognized by their shape (`function` / `tool_call_id`) and
//   stored as v1 record-only traces: `internal: true` and a `tool` tag.
// - `re_message_id` and `forwarded`, which v1 keeps and the UI dropped.
// - `media_placeholder`, which v1 has and the UI could not convert.
//
// Everything else maps as the UI maps it. A content this does not recognize
// is reported, never guessed at.

type V0 = Record<string, unknown> & { type?: unknown };
type Json = unknown;

export type V1Content = Record<string, Json> & { version: "1" };

export type Conversion =
  | { ok: true; content: V1Content }
  | { ok: false; reason: string };

const TEXT_KINDS = new Set(["text", "reaction"]);
const MEDIA_KINDS = new Set(["image", "audio", "video", "document", "sticker"]);

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Keys v1 keeps from any v0 message, when present. */
function base(content: V0) {
  return {
    version: "1" as const,
    ...(typeof content.re_message_id === "string" &&
      { re_message_id: content.re_message_id }),
    ...(content.forwarded === true && { forwarded: true }),
  };
}

function withArtifacts(content: V0) {
  return Array.isArray(content.artifacts)
    ? { artifacts: content.artifacts }
    : {};
}

function parseJson(text: string): { ok: true; value: unknown } | {
  ok: false;
} {
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch {
    return { ok: false };
  }
}

/** A tool call or result, as a v1 record-only trace. */
function toolTrace(
  content: V0,
  event: "use" | "result",
  useId: unknown,
  name: unknown,
  payload: unknown,
): Conversion {
  if (typeof payload !== "string") {
    return { ok: false, reason: `tool ${event} without a string payload` };
  }

  const tool = isObject(content.tool) ? content.tool : {
    use_id: useId,
    provider: "local",
    event,
    type: "function",
    name,
  };

  const common = {
    ...base(content),
    internal: true,
    ...(isObject(content.task) && { task: content.task }),
    tool,
  };

  if (content.v1_type === "data") {
    const parsed = parseJson(payload);
    if (!parsed.ok) {
      return { ok: false, reason: `tool ${event} with non-JSON data` };
    }
    return {
      ok: true,
      content: {
        ...common,
        type: "data",
        kind: "data",
        data: parsed.value,
        ...withArtifacts(content),
      },
    };
  }

  if (content.v1_type === "text") {
    return {
      ok: true,
      content: {
        ...common,
        type: "text",
        kind: "text",
        text: payload,
        ...withArtifacts(content),
      },
    };
  }

  return { ok: false, reason: `tool ${event} without v1_type` };
}

export function toV1Content(content: unknown): Conversion {
  if (!isObject(content)) {
    return { ok: false, reason: "content is not an object" };
  }
  const v0 = content as V0;

  if (v0.version === "1") {
    return { ok: false, reason: "already v1" };
  }

  // Tool call (function call).
  if (isObject(v0.function)) {
    return toolTrace(v0, "use", v0.id, v0.function.name, v0.function.arguments);
  }

  // Tool result (function response).
  if (typeof v0.tool_call_id === "string") {
    return toolTrace(v0, "result", v0.tool_call_id, v0.tool_name, v0.content);
  }

  // Media.
  if (isObject(v0.media)) {
    if (typeof v0.type !== "string" || !MEDIA_KINDS.has(v0.type)) {
      return { ok: false, reason: `media of type ${String(v0.type)}` };
    }
    const media = v0.media;
    if (typeof media.id !== "string" || typeof media.mime_type !== "string") {
      return { ok: false, reason: "media without id or mime_type" };
    }
    const text = v0.type === "audio" ? "" : v0.content;
    return {
      ok: true,
      content: {
        ...base(v0),
        type: "file",
        kind: v0.type,
        file: {
          mime_type: media.mime_type,
          size: typeof media.file_size === "number" ? media.file_size : 0,
          ...(typeof media.filename === "string" && { name: media.filename }),
          uri: media.id,
        },
        ...(typeof text === "string" && { text }),
        ...withArtifacts(v0),
      },
    };
  }

  // Text.
  if (typeof v0.content === "string" && v0.content) {
    if (typeof v0.type !== "string" || !TEXT_KINDS.has(v0.type)) {
      return { ok: false, reason: `text of type ${String(v0.type)}` };
    }
    return {
      ok: true,
      content: {
        ...base(v0),
        type: "text",
        kind: v0.type,
        text: v0.content,
        ...withArtifacts(v0),
      },
    };
  }

  // A medium that arrived without its bytes.
  if (v0.type === "media_placeholder") {
    return {
      ok: true,
      content: {
        ...base(v0),
        type: "data",
        kind: "media_placeholder",
        data: {},
      },
    };
  }

  // Data: the payload is keyed by the type (location, contacts, template…).
  if (typeof v0.type === "string" && v0.type in v0 && v0[v0.type]) {
    return {
      ok: true,
      content: {
        ...base(v0),
        type: "data",
        kind: v0.type,
        data: v0[v0.type],
        ...withArtifacts(v0),
      },
    };
  }

  return {
    ok: false,
    reason: `unrecognized v0 content (type ${String(v0.type)})`,
  };
}
