import { assertEquals } from "jsr:@std/assert@1";
import { isServiceToken, serviceKeys } from "./service_auth.ts";

const env = (vars: Record<string, string>) => ({ get: (k: string) => vars[k] });

Deno.test("serviceKeys: legacy key plus every sb_secret_ key", () => {
  assertEquals(
    serviceKeys(env({
      SUPABASE_SERVICE_ROLE_KEY: "eyJlegacy",
      SUPABASE_SECRET_KEYS: JSON.stringify({
        default: "sb_secret_a",
        ci: "sb_secret_b",
      }),
    })),
    ["eyJlegacy", "sb_secret_a", "sb_secret_b"],
  );
});

Deno.test("serviceKeys: works with only one kind, and ignores bad JSON", () => {
  assertEquals(serviceKeys(env({ SUPABASE_SERVICE_ROLE_KEY: "eyJlegacy" })), [
    "eyJlegacy",
  ]);
  assertEquals(
    serviceKeys(
      env({ SUPABASE_SECRET_KEYS: JSON.stringify({ default: "sb_secret_a" }) }),
    ),
    ["sb_secret_a"],
  );
  assertEquals(serviceKeys(env({ SUPABASE_SECRET_KEYS: "not json" })), []);
});

Deno.test("isServiceToken: accepts a listed key, rejects anything else", () => {
  const keys = ["eyJlegacy", "sb_secret_a"];
  assertEquals(isServiceToken("eyJlegacy", keys), true);
  assertEquals(isServiceToken("sb_secret_a", keys), true);
  assertEquals(isServiceToken("sb_secret_other", keys), false);
  assertEquals(isServiceToken("", keys), false);
  assertEquals(isServiceToken(null, keys), false);
  assertEquals(isServiceToken(undefined, []), false);
});
