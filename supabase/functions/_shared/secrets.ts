// F02. Credentials live in public.secrets, a table only the service role can
// read (see schemas/03_models/03-15_secrets.sql). Rows of organizations,
// organizations_addresses and agents carry the mask '********' where a
// secret used to be. This module puts the real values back for the code
// paths that need them — dispatchers, management functions, agent-client,
// media-preprocessor — all of which already hold the service role.
//
// Nothing here writes: writers keep patching `extra` with the credential and
// the z_extract_secrets trigger stores it.
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "./types/database_types.ts";
import type { Json } from "./db_types.ts";

export const SECRET_MASK = "********";

type JsonObject = { [key: string]: Json | undefined };

type Client = SupabaseClient<Database>;

function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Deep merge of `patch` into `base`; objects recurse, everything else wins. */
function deepMerge(base: JsonObject, patch: JsonObject): JsonObject {
  const out: JsonObject = { ...base };
  for (const [key, value] of Object.entries(patch)) {
    if (value === undefined) continue;
    out[key] = isObject(value) && isObject(out[key])
      ? deepMerge(out[key] as JsonObject, value)
      : value;
  }
  return out;
}

/** The key a tool's secrets are stored under: `type:label` (label, else name). */
export function toolSecretKey(tool: JsonObject): string {
  const type = typeof tool.type === "string" ? tool.type : "";
  const label = typeof tool.label === "string"
    ? tool.label
    : typeof tool.name === "string"
    ? tool.name
    : "";
  return `${type}:${label}`;
}

/**
 * `extra` with the stored secrets merged back in, in the shape the callers
 * expect (`access_token` at the top level, `tools[i].config.password`, …).
 * Pure: the inverse of the trigger, and what the tests pin down.
 */
export function mergeSecrets<T extends JsonObject | null>(
  extra: T,
  secrets: JsonObject | null | undefined,
): T {
  if (!secrets || Object.keys(secrets).length === 0) return extra;

  const { tools: toolSecrets, ...scalar } = secrets;
  let merged = deepMerge((extra ?? {}) as JsonObject, scalar);

  const tools = merged.tools;
  if (Array.isArray(tools) && isObject(toolSecrets)) {
    merged = {
      ...merged,
      tools: tools.map((tool) => {
        if (!isObject(tool)) return tool;
        const secret = toolSecrets[toolSecretKey(tool)];
        if (!isObject(secret)) return tool;
        const config = isObject(tool.config) ? tool.config : {};
        return { ...tool, config: deepMerge(config, secret) };
      }),
    };
  }

  return merged as T;
}

export type SecretScope = "organization" | "address" | "agent";

/** Stored secrets for one source row, or null when there are none. */
export async function loadSecrets(
  client: Client,
  organization_id: string,
  scope: SecretScope,
  ref: string,
): Promise<JsonObject | null> {
  const { data } = await client
    .from("secrets")
    .select("value")
    .eq("organization_id", organization_id)
    .eq("scope", scope)
    .eq("ref", ref)
    .maybeSingle()
    .throwOnError();

  return (data?.value as JsonObject | null) ?? null;
}

/** The stored secrets of one account, e.g. `{ access_token }`, or null. */
export function getAddressSecrets(
  client: Client,
  organization_id: string,
  service: Database["public"]["Enums"]["service"],
  address: string,
): Promise<JsonObject | null> {
  return loadSecrets(
    client,
    organization_id,
    "address",
    `${service}:${address}`,
  );
}

type AddressLike = {
  organization_id: string;
  service: Database["public"]["Enums"]["service"];
  address: string;
  extra: unknown;
};

/** An organizations_addresses row with its credentials restored. */
export async function revealAddress<T extends AddressLike>(
  client: Client,
  row: T,
): Promise<T> {
  const secrets = await loadSecrets(
    client,
    row.organization_id,
    "address",
    `${row.service}:${row.address}`,
  );
  return {
    ...row,
    extra: mergeSecrets(row.extra as JsonObject | null, secrets),
  };
}

/** Same, for a batch: one query, rows keyed by (organization_id, ref). */
export async function revealAddresses<T extends AddressLike>(
  client: Client,
  rows: T[],
): Promise<T[]> {
  if (rows.length === 0) return rows;

  const orgs = [...new Set(rows.map((r) => r.organization_id))];
  const refs = [...new Set(rows.map((r) => `${r.service}:${r.address}`))];

  const { data } = await client
    .from("secrets")
    .select("organization_id, ref, value")
    .eq("scope", "address")
    .in("organization_id", orgs)
    .in("ref", refs)
    .throwOnError();

  const byKey = new Map(
    data.map((s) => [`${s.organization_id}|${s.ref}`, s.value as JsonObject]),
  );

  return rows.map((row) => ({
    ...row,
    extra: mergeSecrets(
      row.extra as JsonObject | null,
      byKey.get(`${row.organization_id}|${row.service}:${row.address}`),
    ),
  }));
}

type AgentLike = { id: string; organization_id: string; extra: unknown };

/** An agents row with its LLM key and tool credentials restored. */
export async function revealAgent<T extends AgentLike>(
  client: Client,
  agent: T,
): Promise<T> {
  const secrets = await loadSecrets(
    client,
    agent.organization_id,
    "agent",
    agent.id,
  );
  return {
    ...agent,
    extra: mergeSecrets(agent.extra as JsonObject | null, secrets),
  };
}

/** Same, for every agent of one organization: one query. */
export async function revealAgents<T extends AgentLike>(
  client: Client,
  agents: T[],
): Promise<T[]> {
  if (agents.length === 0) return agents;

  const { data } = await client
    .from("secrets")
    .select("ref, value")
    .eq("scope", "agent")
    .in("organization_id", [...new Set(agents.map((a) => a.organization_id))])
    .in("ref", agents.map((a) => a.id))
    .throwOnError();

  const byId = new Map(data.map((s) => [s.ref, s.value as JsonObject]));

  return agents.map((agent) => ({
    ...agent,
    extra: mergeSecrets(agent.extra as JsonObject | null, byId.get(agent.id)),
  }));
}

type OrganizationLike = { id: string; extra: unknown };

/** An organizations row with `media_preprocessing.api_key` restored. */
export async function revealOrganization<T extends OrganizationLike>(
  client: Client,
  org: T,
): Promise<T> {
  const secrets = await loadSecrets(client, org.id, "organization", "");
  return {
    ...org,
    extra: mergeSecrets(org.extra as JsonObject | null, secrets),
  };
}
