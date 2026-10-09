// Fail closed: approval and a green workflow from another SHA are insufficient.
import { mkdir, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
const token = process.env.GITHUB_TOKEN;
async function api(path) {
  const response = await fetch(`https://api.github.com${path}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
    },
  });
  if (!response.ok) {
    throw new Error(`GitHub evidence unavailable: ${response.status}`);
  }
  return response;
}
export async function verifiedRun(repo, sha, get = api) {
  if (!/^[a-f0-9]{40}$/.test(sha)) {
    throw new Error("Full immutable SHA required");
  }
  const data = await (await get(
    `/repos/${repo}/actions/workflows/check.yml/runs?head_sha=${sha}&per_page=100`,
  )).json();
  const run =
    data.workflow_runs.filter((r) =>
      r.head_sha === sha && r.head_repository?.full_name === repo
    )
      .sort((a, b) => b.id - a.id)[0];
  if (!run || run.status !== "completed" || run.conclusion !== "success") {
    throw new Error(`Latest Check is not successful for ${repo}@${sha}`);
  }
  return run;
}
if (process.argv[1]?.endsWith("verify-release.mjs")) {
  if (process.env.DEPLOYMENT_OWNER !== "actions") {
    throw new Error(
      "Manual deploy requires DEPLOYMENT_OWNER=actions and the Supabase integration disabled for this environment",
    );
  }
  if (!process.env.SUPABASE_PROJECT_ID) {
    throw new Error("Missing explicit environment project");
  }
  const apiRepo = process.env.GITHUB_REPOSITORY;
  const sha = process.env.GITHUB_SHA;
  const uiRepo = process.env.UI_REPOSITORY || "cq-dropchat/dropchat-ui";
  const uiSha = process.env.UI_SHA;
  const apiRun = await verifiedRun(apiRepo, sha);
  const uiRun = await verifiedRun(uiRepo, uiSha);
  const artifacts =
    await (await api(`/repos/${uiRepo}/actions/runs/${uiRun.id}/artifacts`))
      .json();
  const pair = artifacts.artifacts.find((a) =>
    a.name === `release-pair-${uiSha}` && !a.expired
  );
  if (!pair) throw new Error("Missing paired E2E/types evidence");
  await mkdir("artifacts/release", { recursive: true });
  const archive = await api(
    `/repos/${uiRepo}/actions/artifacts/${pair.id}/zip`,
  );
  await writeFile(
    "artifacts/release/pair.zip",
    Buffer.from(await archive.arrayBuffer()),
  );
  const manifest = JSON.parse(
    execFileSync("unzip", ["-p", "artifacts/release/pair.zip", "pair.json"], {
      encoding: "utf8",
    }),
  );
  if (manifest.api_sha !== sha || manifest.ui_sha !== uiSha) {
    throw new Error("Pair does not match the promoted immutable SHAs");
  }
  await writeFile(
    "artifacts/release/evidence.json",
    JSON.stringify(
      {
        api_sha: sha,
        ui_sha: uiSha,
        api_run: apiRun.html_url,
        ui_run: uiRun.html_url,
        project: process.env.SUPABASE_PROJECT_ID,
        verified_at: new Date().toISOString(),
      },
      null,
      2,
    ),
  );
}
