import { createClient as createClientBase } from "@supabase/supabase-js";
import type { Database } from "./types/database_types.ts";
import { currentRequestId } from "./logger.ts";

// F26: every request to Supabase made while handling an Edge Function request
// carries its `x-request-id`. PostgREST exposes it to the triggers in
// `request.headers`, and the triggers that call the next function forward it
// (public.request_id_header), so one chain logs one id. Read at call time,
// not at client creation, so a client kept across requests stays correct;
// `globalThis.fetch` is looked up per call too (tests stub it).
function fetchWithRequestId(
  input: RequestInfo | URL,
  init?: RequestInit,
): Promise<Response> {
  const requestId = currentRequestId();
  if (!requestId) return globalThis.fetch(input, init);

  const headers = new Headers(
    init?.headers ?? (input instanceof Request ? input.headers : undefined),
  );
  headers.set("x-request-id", requestId);
  return globalThis.fetch(input, { ...init, headers });
}

export function createClient(req: Request) {
  if (!Deno.env.get("SUPABASE_URL")) {
    throw new Error("Undefined SUPABASE_URL env var.");
  }

  if (!Deno.env.get("SUPABASE_ANON_KEY")) {
    throw new Error("Undefined SUPABASE_ANON_KEY env var.");
  }

  const authHeader = req.headers.get("Authorization");

  if (!authHeader) {
    throw new Error("Missing Authorization header");
  }

  const token = authHeader.split(" ")[1];

  if (!token) {
    throw new Error("Invalid Authorization header format");
  }

  return createClientBase<Database>(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    {
      auth: { persistSession: false },
      global: {
        fetch: fetchWithRequestId,
        headers: {
          Authorization: `Bearer ${token}`,
        },
      },
    },
  );
}

export function createApiClient(req: Request) {
  if (!Deno.env.get("SUPABASE_URL")) {
    throw new Error("Undefined SUPABASE_URL env var.");
  }

  if (!Deno.env.get("SUPABASE_ANON_KEY")) {
    throw new Error("Undefined SUPABASE_ANON_KEY env var.");
  }

  const authHeader = req.headers.get("Authorization");

  if (!authHeader) {
    throw new Error("Missing Authorization header");
  }

  const token = authHeader.split(" ")[1];

  if (!token) {
    throw new Error("Invalid Authorization header format");
  }

  return createClientBase<Database>(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    {
      auth: { persistSession: false },
      global: {
        fetch: fetchWithRequestId,
        headers: {
          "api-key": token,
        },
      },
    },
  );
}

// API-key-scoped client from a raw key (no request needed): forwards the org
// API key in the `api-key` header so RLS resolves the org via the api-key
// path. auth.uid() stays null; the key's role bounds access.
export function createApiClientFromKey(apiKey: string) {
  if (!Deno.env.get("SUPABASE_URL")) {
    throw new Error("Undefined SUPABASE_URL env var.");
  }

  if (!Deno.env.get("SUPABASE_ANON_KEY")) {
    throw new Error("Undefined SUPABASE_ANON_KEY env var.");
  }

  return createClientBase<Database>(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    {
      auth: { persistSession: false },
      global: {
        fetch: fetchWithRequestId,
        headers: {
          "api-key": apiKey,
        },
      },
    },
  );
}

export function createUnsecureClient() {
  if (!Deno.env.get("SUPABASE_URL")) {
    throw new Error("Undefined SUPABASE_URL env var.");
  }

  if (!Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) {
    throw new Error("Undefined SUPABASE_SERVICE_ROLE_KEY env var.");
  }

  return createClientBase<Database>(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    {
      auth: { persistSession: false },
      global: { fetch: fetchWithRequestId },
    },
  );
}
