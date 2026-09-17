import { assertEquals } from "jsr:@std/assert@1";
import { mergeSecrets, SECRET_MASK, toolSecretKey } from "./secrets.ts";

// F02: the pure inverse of the z_extract_secrets trigger.

Deno.test("mergeSecrets: a top-level token replaces its mask", () => {
  const extra = { waba_id: "3", access_token: SECRET_MASK };
  assertEquals(
    mergeSecrets(extra, { access_token: "EAAG-test" }),
    { waba_id: "3", access_token: "EAAG-test" },
  );
});

Deno.test("mergeSecrets: nested paths merge without dropping siblings", () => {
  const extra = {
    media_preprocessing: { mode: "active", api_key: SECRET_MASK },
    error_messages_direction: "internal",
  };
  assertEquals(
    mergeSecrets(extra, { media_preprocessing: { api_key: "AIza-test" } }),
    {
      media_preprocessing: { mode: "active", api_key: "AIza-test" },
      error_messages_direction: "internal",
    },
  );
});

Deno.test("mergeSecrets: tool credentials follow type:label, not the index", () => {
  const extra = {
    api_key: SECRET_MASK,
    tools: [
      {
        provider: "local",
        type: "http",
        label: "erp-api",
        config: {
          url: "https://erp.test/*",
          headers: { Authorization: SECRET_MASK },
        },
      },
      {
        provider: "local",
        type: "sql",
        label: "erp-db",
        config: { driver: "postgres", host: "db.test", password: SECRET_MASK },
      },
      { provider: "local", type: "function", name: "calculator" },
    ],
  };
  const secrets = {
    api_key: "sk-test",
    tools: {
      "sql:erp-db": { password: "P@ss" },
      "http:erp-api": { headers: { Authorization: "Bearer x" } },
    },
  };

  const merged = mergeSecrets(extra, secrets) as typeof extra;

  assertEquals(merged.api_key, "sk-test");
  assertEquals(merged.tools[0].config, {
    url: "https://erp.test/*",
    headers: { Authorization: "Bearer x" },
  });
  assertEquals(merged.tools[1].config, {
    driver: "postgres",
    host: "db.test",
    password: "P@ss",
  });
  assertEquals(merged.tools[2], extra.tools[2]);
});

Deno.test("mergeSecrets: no secrets returns the input untouched", () => {
  const extra = { mode: "active" };
  assertEquals(mergeSecrets(extra, null), extra);
  assertEquals(mergeSecrets(extra, {}), extra);
  assertEquals(mergeSecrets(null, { access_token: "t" }), {
    access_token: "t",
  });
});

Deno.test("toolSecretKey: label, else name, else empty", () => {
  assertEquals(toolSecretKey({ type: "sql", label: "erp" }), "sql:erp");
  assertEquals(
    toolSecretKey({ type: "function", name: "calc" }),
    "function:calc",
  );
  assertEquals(toolSecretKey({ type: "mcp" }), "mcp:");
});
