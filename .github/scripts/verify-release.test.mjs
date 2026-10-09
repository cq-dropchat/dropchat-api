import { test } from "node:test";
import { strict as assert } from "node:assert";
import { verifiedRun } from "./verify-release.mjs";
const sha = "a".repeat(40);
const get = (runs) => async () => ({
  json: async () => ({ workflow_runs: runs }),
});
test("reject missing, stale, skipped, failed and foreign-repository checks", async () => {
  for (
    const run of [
      undefined,
      { head_sha: "b".repeat(40), status: "completed", conclusion: "success" },
      { head_sha: sha, status: "completed", conclusion: "skipped" },
      { head_sha: sha, status: "completed", conclusion: "failure" },
      {
        head_sha: sha,
        status: "completed",
        conclusion: "success",
        head_repository: { full_name: "fork/repo" },
      },
    ]
  ) {
    await assert.rejects(verifiedRun("owner/repo", sha, get(run ? [run] : [])));
  }
});
test("accept completed exact SHA from the same repository", async () => {
  const run = {
    id: 1,
    head_sha: sha,
    status: "completed",
    conclusion: "success",
    head_repository: { full_name: "owner/repo" },
  };
  assert.deepEqual(await verifiedRun("owner/repo", sha, get([run])), run);
});

test("a newer failed or running Check supersedes an older green Check", async () => {
  const good = {
    id: 1,
    head_sha: sha,
    status: "completed",
    conclusion: "success",
    head_repository: { full_name: "owner/repo" },
  };
  for (
    const bad of [{ id: 2, status: "completed", conclusion: "failure" }, {
      id: 3,
      status: "in_progress",
      conclusion: null,
    }]
  ) {
    await assert.rejects(
      verifiedRun("owner/repo", sha, get([good, { ...good, ...bad }])),
    );
  }
});
