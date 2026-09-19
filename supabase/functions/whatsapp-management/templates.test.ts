import { assertEquals } from "jsr:@std/assert@1";
import { pickAccessToken } from "./templates.ts";

// Templates used to call Meta with an empty token when the address had none
// of its own, while the dispatcher and the webhook fall back to the system
// user's token.
Deno.test("pickAccessToken: the address's own token wins", () => {
  assertEquals(pickAccessToken({ access_token: "own" }, "system"), "own");
});

Deno.test("pickAccessToken: no stored secrets falls back to the system token", () => {
  assertEquals(pickAccessToken(null, "system"), "system");
  assertEquals(pickAccessToken(undefined, "system"), "system");
  assertEquals(pickAccessToken({}, "system"), "system");
});

Deno.test("pickAccessToken: an empty or non-string token falls back too", () => {
  assertEquals(pickAccessToken({ access_token: "" }, "system"), "system");
  assertEquals(pickAccessToken({ access_token: 42 }, "system"), "system");
});
