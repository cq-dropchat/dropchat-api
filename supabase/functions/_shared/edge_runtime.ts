// Ack first, work after the response. `EdgeRuntime.waitUntil` keeps the
// worker alive until the promise settles on the deployed runtime (and on
// `supabase functions serve`); where it is missing — plain `deno test`,
// other tooling — the work is awaited inline so nothing is lost.
//
// The Slack webhook has done this since it was written; F05 brings the Meta
// webhooks in line: Meta retries (and eventually disables) a webhook that
// takes too long, and a history batch with twenty media downloads did.

type Runtime = {
  EdgeRuntime?: { waitUntil(p: Promise<unknown>): void };
};

export function waitUntil(work: Promise<unknown>): Promise<unknown> | void {
  const runtime = globalThis as unknown as Runtime;

  if (runtime.EdgeRuntime?.waitUntil) {
    runtime.EdgeRuntime.waitUntil(work);
    return;
  }

  return work;
}

/** Whether the runtime can run work after the response. */
export function hasWaitUntil(): boolean {
  return Boolean((globalThis as unknown as Runtime).EdgeRuntime?.waitUntil);
}
