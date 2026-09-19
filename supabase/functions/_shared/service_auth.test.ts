import { assertEquals } from "jsr:@std/assert@1";
import { isServiceToken, serviceKeys, tokenShape } from "./service_auth.ts";

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

Deno.test("tokenShape: describes a token without its value", () => {
  const payload = btoa(
    JSON.stringify({ role: "service_role", ref: "abc", iat: 1 }),
  )
    .replace(/=+$/, "");
  const jwt = `eyJhbGciOiJIUzI1NiJ9.${payload}.signature`;
  assertEquals(tokenShape(jwt), {
    kind: "jwt",
    length: jwt.length,
    role: "service_role",
    ref: "abc",
    iat: 1,
  });
  assertEquals(tokenShape("sb_secret_xyz"), { kind: "sb_secret", length: 13 });
  assertEquals(tokenShape("plain"), { kind: "other", length: 5 });
  assertEquals(tokenShape(undefined), { kind: "none", length: 0 });
});
