/**
 * Unified configuration for the OpenBSP plugin.
 *
 * Priority: env vars > config.json > hardcoded defaults.
 * Production defaults (Supabase URL + anon key) are baked in — these are
 * public values already embedded in the UI bundle. Zero-config for hosted users.
 */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// ── Constants ────────────────────────────────────────────────────────────

export const STATE_DIR = Deno.env.get("OPENBSP_STATE_DIR") ??
  join(homedir(), ".claude", "channels", "openbsp");

export const CONFIG_FILE = join(STATE_DIR, "config.json");
export const SESSION_FILE = join(STATE_DIR, "session.json");

// No built-in project. The url and the key are a PAIR — a key authenticates
// against the project it was issued for and no other — and a pair frozen in
// source drifts the moment the project changes: the url here outlived its
// project, kept resolving, and answered every request 401, which reads as a
// bad key rather than a wrong address. Supplying them together, from the
// environment or config.json, is the only way they cannot disagree.

// ── Types ────────────────────────────────────────────────────────────────

export type Config = {
  supabaseUrl?: string;
  supabaseAnonKey?: string;
  orgId?: string;
  accountPhone?: string;
  allowedContacts: string[];
};

type ConfigFile = {
  supabaseUrl?: string;
  supabaseAnonKey?: string;
  orgId?: string;
  accountPhone?: string;
  allowedContacts?: string[];
};

// ── Load / Save ──────────────────────────────────────────────────────────

function readConfigFile(): ConfigFile {
  try {
    const raw = readFileSync(CONFIG_FILE, "utf8");
    return JSON.parse(raw) as ConfigFile;
  } catch {
    return {};
  }
}

/**
 * Load configuration with full priority chain: env vars > config.json.
 *
 * The project may be unresolved here; `requireEndpoint` is what refuses to
 * guess. Callers that only want `allowedContacts` do not need a project at
 * all, so loading stays total.
 */
export function loadConfig(): Config {
  const file = readConfigFile();

  return {
    supabaseUrl: Deno.env.get("SUPABASE_URL") ?? file.supabaseUrl,
    supabaseAnonKey: Deno.env.get("SUPABASE_ANON_KEY") ?? file.supabaseAnonKey,
    orgId: Deno.env.get("ORG_ID") ?? file.orgId ?? undefined,
    accountPhone: Deno.env.get("ACCOUNT_PHONE") ?? file.accountPhone ??
      undefined,
    allowedContacts: file.allowedContacts ?? [],
  };
}

/**
 * The project this plugin talks to, or a refusal that says how to name one.
 *
 * Both halves are demanded at once: a url without its key is the mismatch
 * this indirection exists to prevent.
 */
export function requireEndpoint(): { url: string; anonKey: string } {
  const { supabaseUrl, supabaseAnonKey } = loadConfig();

  if (!supabaseUrl || !supabaseAnonKey) {
    throw new Error(
      "No Supabase project configured. Set SUPABASE_URL and " +
        "SUPABASE_ANON_KEY, or write supabaseUrl and supabaseAnonKey to " +
        CONFIG_FILE + ".",
    );
  }

  return { url: supabaseUrl, anonKey: supabaseAnonKey };
}

/**
 * Atomic write: tmp file + rename, 0o600 permissions.
 */
export function saveConfig(config: ConfigFile): void {
  mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
  const tmp = CONFIG_FILE + ".tmp";
  writeFileSync(tmp, JSON.stringify(config, null, 2) + "\n", {
    mode: 0o600,
  });
  Deno.renameSync(tmp, CONFIG_FILE);
}
