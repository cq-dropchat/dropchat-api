// The suite's own preconditions, checked instead of assumed.
//
// Yesterday's lesson was that a test which skips itself in silence proves
// nothing; this is the same lesson from the other side. A precondition that
// every machine happened to satisfy is invisible until one machine does not,
// and then it does not announce itself — it degrades into a race, which is
// how four tests failed on the first CI run this repository ever had, and
// five on a laptop from the same commit.
import "./env.ts";
import { assert } from "jsr:@std/assert@1";
import { edgeRuntimeIsUp, supabaseIsUp } from "./env.ts";

const up = await supabaseIsUp();

Deno.test({
  name: "the integration tests are the only thing dispatching",
  ignore: !up,
  async fn() {
    assert(
      !(await edgeRuntimeIsUp()),
      "an edge runtime is serving /functions/v1: it answers the triggers' " +
        "pg_net posts with a second, unstubbed copy of the function under " +
        "test, takes the dispatch lease before the in-process handler() and " +
        "sends real requests to graph.facebook.com with fixture tokens. " +
        "Restart with: supabase start -x edge-runtime",
    );
  },
});
