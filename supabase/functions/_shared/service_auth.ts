// Internal calls (database triggers with the Vault's edge_functions_token, the
// cron sweeps, one function calling another) authenticate with a project
// secret key. Accept both kinds: the legacy service_role JWT
// (SUPABASE_SERVICE_ROLE_KEY) and the sb_secret_ keys Supabase injects as a JSON
// dictionary in SUPABASE_SECRET_KEYS. Legacy keys are retired at the end of
// 2026, so the Vault token can move to a secret key without touching code.

type Env = { get(key: string): string | undefined };

/** Every key that identifies an internal caller, legacy first. */
export function serviceKeys(env: Env = Deno.env): string[] {
  const keys: string[] = [];

  const legacy = env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) keys.push(legacy);

  const raw = env.get("SUPABASE_SECRET_KEYS");
  if (raw) {
    try {
      const parsed: unknown = JSON.parse(raw);
      if (parsed && typeof parsed === "object") {
        for (const value of Object.values(parsed)) {
          if (typeof value === "string" && value) keys.push(value);
        }
      }
    } catch {
      // Not JSON: nothing to add beyond the legacy key.
    }
  }

  return keys;
}

/** Whether `token` (the bearer, without "Bearer ") is one of the project's secret keys. */
export function isServiceToken(
  token: string | null | undefined,
  keys: string[] = serviceKeys(),
): boolean {
  return !!token && keys.includes(token);
}

/**
 * A token's shape for logs, never its value: kind, length and, for a JWT, the
 * non-secret claims that tell two service_role keys apart.
 */
export function tokenShape(token: string | null | undefined): {
  kind: "none" | "jwt" | "sb_secret" | "other";
  length: number;
  role?: string;
  ref?: string;
  iat?: number;
} {
  if (!token) return { kind: "none", length: 0 };
  if (token.startsWith("sb_secret_")) {
    return { kind: "sb_secret", length: token.length };
  }
  const parts = token.split(".");
  if (parts.length === 3) {
    try {
      const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
      const claims = JSON.parse(
        atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4)),
      );
      return {
        kind: "jwt",
        length: token.length,
        role: claims.role,
        ref: claims.ref,
        iat: claims.iat,
      };
    } catch {
      // not a readable JWT
    }
  }
  return { kind: "other", length: token.length };
}
