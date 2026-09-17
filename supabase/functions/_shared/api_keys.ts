// F14. API keys are stored as sha256 (public.api_keys.key_hash); the plain
// key only ever travels in the `api-key` header. Functions that look a key
// up themselves (the management functions, the MCP server) hash it the same
// way the database does and filter on the hash.
import type { SupabaseClient } from "@supabase/supabase-js";
import type { ApiKeyRow, Database } from "./types/database_types.ts";

/** sha256 of the key as PostgREST's bytea literal (`\x…`). */
export async function hashApiKey(key: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(key),
  );
  return "\\x" + Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * The api_keys row behind a plain key, or null. Goes through the caller's
 * client, so RLS still applies: an API-key client sees its own row (the
 * self-read branch of the policy compares the same hash), a service-role
 * client sees any. An expired key is null either way.
 */
export async function findApiKey(
  client: SupabaseClient<Database>,
  key: string,
): Promise<ApiKeyRow | null> {
  const { data, error } = await client
    .from("api_keys")
    .select()
    .eq("key_hash", await hashApiKey(key))
    .maybeSingle();

  if (error) throw error;
  if (!data) return null;
  if (data.expires_at && new Date(data.expires_at) <= new Date()) return null;

  return data;
}
