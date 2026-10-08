// Pure regressions: no provider calls, database writes, or customer messages.
import {
  assertEquals,
  assertInstanceOf,
  assertRejects,
} from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  AgentProtocolHandler,
  RequestContext,
  ResponseContext,
} from "./protocols/base.ts";
import {
  ChatCompletionsHandler,
  type ChatCompletionsResponse,
} from "./protocols/chat-completions.ts";
import { AgentOutputError } from "./protocols/output.ts";
import {
  ResponsesHandler,
  type ResponsesResponseWrapper,
} from "./protocols/responses.ts";
import { requestAgentResponse } from "./response.ts";

const context = {
  organization: { id: "org-1" },
  conversation: {
    id: "conv-1",
    organization_id: "org-1",
    service: "whatsapp",
    organization_address: "sender",
    address: "recipient",
  },
  agent: { id: "agent-1", extra: {} },
  messages: [],
} as unknown as RequestContext;
const details = {
  conversation_id: "conv-1",
  message_id: "message-1",
  agent_id: "agent-1",
};
const noClient = null as unknown as SupabaseClient;

function chat(
  content: string | null = null,
  finish_reason: ChatCompletionsResponse["finish_reason"] = "stop",
  args?: string,
): ChatCompletionsResponse {
  return {
    finish_reason,
    message: {
      role: "assistant",
      content,
      refusal: null,
      ...(args !== undefined && {
        tool_calls: [{
          id: "call-1",
          type: "function",
          function: { name: "respond", arguments: args },
        }],
      }),
    },
  };
}

function respond(args: string): ResponsesResponseWrapper {
  return {
    status: "completed",
    output: [{
      type: "function_call",
      name: "respond",
      arguments: args,
      call_id: "call-1",
    }],
  };
}

const handlers = {
  chat: new ChatCompletionsHandler([], context, noClient),
  responses: new ResponsesHandler([], context, noClient),
};

for (const [name, handler] of Object.entries(handlers)) {
  const output = (args: string) =>
    name === "chat" ? chat(null, "tool_calls", args) : respond(args);
  // Each handler is exercised with its protocol's wire format.
  const process = (args: string) =>
    (handler as AgentProtocolHandler).processResponse(output(args));

  Deno.test(`${name}: only an explicit empty respond array permits silence`, async () => {
    assertEquals(await process('{"messages":[]}'), {
      messages: [],
      skipResponse: true,
    });
  });

  for (
    const args of [
      "{",
      "null",
      "{}",
      '{"messages":null}',
      '{"messages":{}}',
      '{"messages":[{"type":"text","text":"  "}]}',
      '{"messages":[{"type":"text","text":17}]}',
      '{"messages":[{"type":"unknown"}]}',
      '{"messages":[{"type":"file","uri":""}]}',
      '{"messages":[{"type":"text","text":"Hola"},null]}',
    ]
  ) {
    Deno.test(`${name}: rejects unusable respond arguments ${args}`, async () => {
      await assertRejects(() => process(args), AgentOutputError);
    });
  }

  Deno.test(`${name}: preserves a valid multi-message answer`, async () => {
    const result = await process(JSON.stringify({
      messages: [{ type: "text", text: "Hola" }, {
        type: "text",
        text: "¿Cuál es tu comuna?",
      }],
    }));
    assertEquals(result.messages?.map((m) => m.content), [
      { version: "1", type: "text", kind: "text", text: "Hola" },
      {
        version: "1",
        type: "text",
        kind: "text",
        text: "¿Cuál es tu comuna?",
      },
    ]);
    assertEquals(result.skipResponse, undefined);
  });
}

Deno.test("chat: consumes valid tool calls even when a provider reports stop", async () => {
  const result = await handlers.chat.processResponse(
    chat(null, "stop", '{"messages":[{"type":"text","text":"Hola"}]}'),
  );
  assertEquals(result.messages?.length, 1);
});

Deno.test("chat: truncated output never executes even apparently complete tool arguments", async () => {
  await assertRejects(
    () =>
      handlers.chat.processResponse(chat(null, "length", '{"messages":[]}')),
    AgentOutputError,
    "output_truncated",
  );
});

Deno.test("chat: blank content cannot count as an answer", async () => {
  await assertRejects(
    () => handlers.chat.processResponse(chat("  \n")),
    AgentOutputError,
    "empty_response",
  );
});

Deno.test("responses: incomplete output never executes tool calls", async () => {
  await assertRejects(
    () =>
      handlers.responses.processResponse({
        ...respond('{"messages":[]}'),
        status: "incomplete",
        incomplete_details: { reason: "max_output_tokens" },
      }),
    AgentOutputError,
    "response_incomplete",
  );
});

Deno.test("responses: reasoning without an answer is a recoverable failure", async () => {
  await assertRejects(
    () =>
      handlers.responses.processResponse({
        status: "completed",
        output: [{ type: "reasoning", id: "r1", summary: [] }],
      }),
    AgentOutputError,
    "empty_response",
  );
});

function scripted(script: (call: number) => ResponseContext) {
  let calls = 0;
  const handler: AgentProtocolHandler<null, ResponseContext> = {
    prepareRequest: () => Promise.resolve(null),
    sendRequest: () => Promise.resolve(script(++calls)),
    processResponse: (response) => Promise.resolve(response),
  };
  return { handler, calls: () => calls };
}

const answer: ResponseContext = {
  messages: [{
    organization_id: "org-1",
    service: "whatsapp",
    organization_address: "sender",
    content: { version: "1", type: "text", kind: "text", text: "Hola" },
  }],
};

Deno.test("recovery: retries empty output once and returns the answer", async () => {
  const stub = scripted((call) => call === 1 ? { messages: [] } : answer);
  assertEquals(
    await requestAgentResponse(
      stub.handler,
      () => Promise.resolve(true),
      details,
    ),
    answer,
  );
  assertEquals(stub.calls(), 2);
});

Deno.test("recovery: persistent emptiness fails after two attempts", async () => {
  const stub = scripted(() => ({ messages: [] }));
  await assertRejects(
    () =>
      requestAgentResponse(stub.handler, () => Promise.resolve(true), details),
    AgentOutputError,
    "empty_response",
  );
  assertEquals(stub.calls(), 2);
});

Deno.test("recovery: an explicit skip and a normal answer do not retry", async () => {
  for (const response of [answer, { messages: [], skipResponse: true }]) {
    const stub = scripted(() => response);
    assertEquals(
      await requestAgentResponse(
        stub.handler,
        () => Promise.resolve(true),
        details,
      ),
      response,
    );
    assertEquals(stub.calls(), 1);
  }
});

Deno.test("recovery: a superseding message or human takeover prevents the retry", async () => {
  const stub = scripted(() => ({ messages: [] }));
  let checks = 0;
  assertEquals(
    await requestAgentResponse(
      stub.handler,
      () => Promise.resolve(++checks === 1),
      details,
    ),
    null,
  );
  assertEquals(stub.calls(), 1);
});

Deno.test("recovery: provider refusal is terminal and never retried", async () => {
  for (
    const process of [
      () => handlers.chat.processResponse(chat(null, "content_filter")),
      () =>
        handlers.responses.processResponse({
          output: [],
          status: "incomplete",
          incomplete_details: { reason: "content_filter" },
        }),
    ]
  ) {
    const stub = scripted(() => ({ messages: [] }));
    stub.handler.processResponse = process;
    const error = await assertRejects(() =>
      requestAgentResponse(stub.handler, () => Promise.resolve(true), details)
    );
    assertInstanceOf(error, AgentOutputError);
    assertEquals(error.retryable, false);
    assertEquals(stub.calls(), 1);
  }
});
