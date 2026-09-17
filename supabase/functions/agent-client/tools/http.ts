/**
 * Fetch tool
 *
 * {
 *   "provider": "local",
 *   "type": "fetch",
 *   "client_label": "my_client",
 *   "headers": {
 *     "Authorization": "Bearer 1234567890",
 *     "X-Organization-Address": "$context.conversation.organization_address"
 *   }
 * }
 *
 * This tool inherits from the base Fetch tool. It makes tools based on HTTP requests.
 *
 * {
 *   "client_label": "my_client",
 *   "name": "create_user",
 *   "description": "Create a user",
 *   "input": {
 *     "type": "object",
 *     "properties": {
 *       "organization_id": { "type": "string" },
 *       "user_name": { "type": "string" }
 *     },
 *     "required": ["organization_id", "user_name"]
 *   },
 *   "request": {
 *     "url": "https://api.example.com/organizations/$input.organization_id/users",
 *     "method": "POST",
 *     "headers": {
 *       "Authorization": "Bearer 1234567890",
 *       "X-Contact-Address": "$context.conversation.contact_address"
 *     },
 *     "body": {
 *       "name": "$input.user_name"
 *     }
 *   }
 * }
 */

import * as z from "zod";
import {
  assertPublicUrl,
  DestinationError,
  type GuardOptions,
} from "../../_shared/net_guard.ts";
import { contextHeaders, type RequestContext } from "../protocols/base.ts";
import type { LocalHTTPToolConfig } from "../../_shared/supabase.ts";
import type { ToolDefinition } from "./base.ts";

export const RequestToolInputSchema = z.object({
  url: z.string().describe("The request URL"),
  method: z.enum(["GET", "POST", "PUT", "PATCH", "DELETE"]),
  headers: z.record(z.string(), z.string()).optional(),
  body: z
    .looseObject({})
    .optional()
    .describe("JSON payload. If present, the correct header will be set."),
});

export const RequestToolOutputSchema = z.union([
  z.object({
    status: z.number(),
    isError: z.literal(true),
    message: z.string(),
  }),
  z.object({
    status: z.number(),
    isError: z.literal(false),
    body: z.looseObject({}),
  }),
]);

/** Model-chosen request headers that may pass through (F08). */
const FORWARDABLE_INPUT_HEADERS = new Set(["content-type", "accept"]);

const HTTP_TOOL_TIMEOUT_MS = 10_000;

export async function requestToolImplementation(
  input: z.infer<typeof RequestToolInputSchema>,
  config: LocalHTTPToolConfig["config"],
  context: RequestContext,
  _client?: unknown,
  // Test seams: the DNS resolver and the timeout.
  options: GuardOptions & { timeoutMs?: number } = {},
): Promise<z.infer<typeof RequestToolOutputSchema>> {
  // TODO: $context.conversation.contact_address value-like replacement

  // Security check: URL restriction
  if (config.url) {
    if (config.url.endsWith("/*")) {
      const baseUrl = config.url.slice(0, -2);
      if (!input.url.startsWith(baseUrl)) {
        return {
          status: 403,
          isError: true,
          message: `URL not allowed. Must start with ${baseUrl}`,
        };
      }
    } else {
      if (input.url !== config.url) {
        return {
          status: 403,
          isError: true,
          message: `URL not allowed. Must match ${config.url}`,
        };
      }
    }
  }

  // Security check: Method restriction
  if (config.methods && config.methods.length > 0) {
    if (!config.methods.includes(input.method)) {
      return {
        status: 403,
        isError: true,
        message: `Method ${input.method} not allowed. Allowed: ${
          config.methods.join(", ")
        }`,
      };
    }
  }

  // F08: the destination must be public — config.url is optional, and even
  // when set it is an admin's string, not a proof.
  try {
    await assertPublicUrl(input.url, options);
  } catch (error) {
    if (!(error instanceof DestinationError)) throw error;
    return { status: 403, isError: true, message: error.message };
  }

  // F08: the model does not choose credentials. Only content negotiation
  // headers pass from the input; everything else comes from the config.
  // Headers normalises case, so a later source replaces an earlier one
  // instead of being appended next to it.
  const headers = new Headers(contextHeaders(context));
  for (const [name, value] of Object.entries(input.headers ?? {})) {
    if (FORWARDABLE_INPUT_HEADERS.has(name.toLowerCase())) {
      headers.set(name, value);
    }
  }
  if (input.body !== undefined && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }
  for (const [name, value] of Object.entries(config.headers ?? {})) {
    headers.set(name, value);
  }

  let response: Response;

  try {
    response = await fetch(input.url, {
      method: input.method,
      headers,
      body: input.body !== undefined ? JSON.stringify(input.body) : undefined,
      // F08: a redirect is an answer, not an instruction — following it would
      // let a public URL bounce the request to a private address.
      redirect: "manual",
      signal: AbortSignal.timeout(options.timeoutMs ?? HTTP_TOOL_TIMEOUT_MS),
    });
  } catch (error) {
    return {
      status: 504,
      isError: true,
      message: error instanceof Error ? error.message : String(error),
    };
  }

  if (response.status >= 300 && response.status < 400) {
    return {
      status: response.status,
      isError: true,
      message: `Redirect to ${
        response.headers.get("location") ?? "(none)"
      } not followed`,
    };
  }

  if (!response.ok) {
    return {
      status: response.status,
      isError: true,
      message: await response.text(),
    };
  }

  const text = await response.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = { text };
  }

  return {
    status: response.status,
    isError: false,
    body,
  };
}

export const RequestTool: ToolDefinition<
  typeof RequestToolInputSchema,
  typeof RequestToolOutputSchema,
  LocalHTTPToolConfig["config"]
> = {
  provider: "local",
  type: "http",
  name: "request",
  description: "HTTP client. Works with JSON payloads only.",
  inputSchema: z.toJSONSchema(RequestToolInputSchema),
  outputSchema: z.toJSONSchema(RequestToolOutputSchema),
  implementation: requestToolImplementation,
};

export const HTTPTools = [RequestTool];
