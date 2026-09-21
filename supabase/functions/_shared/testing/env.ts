// Environment for tests that talk to a local Supabase (`supabase start`).
// The keys below are the CLI's well-known demo credentials — identical on
// every machine, secret to nobody — and only take effect when the variable is
// not already set (CI exports the real local values from `supabase status`).

const DEFAULTS: Record<string, string> = {
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_ANON_KEY:
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0",
  SUPABASE_SERVICE_ROLE_KEY:
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU",
  SUPABASE_DB_URL: "postgresql://postgres:postgres@127.0.0.1:54322/postgres",
  // Webhook secrets the handlers read at import time. Fake, test-only.
  META_APP_ID: "100000000000000",
  META_APP_SECRET: "meta-app-secret-test",
  INSTAGRAM_APP_ID: "200000000000000",
  INSTAGRAM_APP_SECRET: "instagram-app-secret-test",
  SLACK_SIGNING_SECRET: "slack-signing-secret-test",
  WHATSAPP_VERIFY_TOKEN: "verify-token-test",
};

for (const [name, value] of Object.entries(DEFAULTS)) {
  if (!Deno.env.get(name)) Deno.env.set(name, value);
}

export const env = {
  get url() {
    return Deno.env.get("SUPABASE_URL")!;
  },
  get anonKey() {
    return Deno.env.get("SUPABASE_ANON_KEY")!;
  },
  get serviceRoleKey() {
    return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  },
  get metaAppSecret() {
    return Deno.env.get("META_APP_SECRET")!;
  },
  get instagramAppSecret() {
    return Deno.env.get("INSTAGRAM_APP_SECRET")!;
  },
  get slackSigningSecret() {
    return Deno.env.get("SLACK_SIGNING_SECRET")!;
  },
};

/** Whether a local Supabase answers; integration tests skip when it does not. */
export async function supabaseIsUp(): Promise<boolean> {
  try {
    const res = await fetch(`${env.url}/rest/v1/`, {
      headers: { apikey: env.anonKey },
    });
    await res.body?.cancel();
    return res.ok;
  } catch {
    return false;
  }
}

/**
 * Whether a local edge runtime is serving the functions from disk.
 *
 * It must NOT be, and the whole suite depends on that. These tests call each
 * function's `handler()` in process and stub `globalThis.fetch`; the rows they
 * insert also fire the triggers, which pg_net posts to `/functions/v1/…`. An
 * edge runtime answers that post by running a SECOND copy of the same
 * function, out of process, whose fetch nothing stubs — it takes the dispatch
 * lease first, and the in-process `handler()` then finds nothing to claim.
 * Start the stack with `-x edge-runtime`.
 *
 * Told apart by what Kong answers for a function that needs auth: 401 when a
 * runtime is behind it, 503 `name resolution failed` when the container is not
 * there to resolve.
 */
export async function edgeRuntimeIsUp(): Promise<boolean> {
  try {
    const res = await fetch(`${env.url}/functions/v1/whatsapp-dispatcher`, {
      method: "POST",
    });
    await res.body?.cancel();
    return res.status !== 503;
  } catch {
    return false;
  }
}

/** Ids and values from supabase/tests/fixtures/seed_test.sql. */
export const fixture = {
  orgA: "aaaaaaaa-0000-4000-8000-000000000001",
  orgB: "bbbbbbbb-0000-4000-8000-000000000001",
  agentAlice: "aaaaaaaa-0000-4000-8000-00000000a0a1",
  agentRobotA: "aaaaaaaa-0000-4000-8000-00000000a0a9",
  keyAMember: "test-key-a-member-000000000000000000",
  keyAOwner: "test-key-a-owner-0000000000000000000",
  keyBMember: "test-key-b-member-000000000000000000",
  waA: "100000000000001",
  waB: "200000000000001",
  wabaA: "300000000000001",
  contactA1: "5491100000101",
  contactA2: "5491100000102",
  contactB1: "5492200000201",
  convA1: "aaaaaaaa-0000-4000-8000-0000000000c1",
  convB1: "bbbbbbbb-0000-4000-8000-0000000000c1",
  msgA1Out: "aaaaaaaa-0000-4000-8000-00000000d0a2",
  webhookA: "aaaaaaaa-0000-4000-8000-00000000e0a1",
};
