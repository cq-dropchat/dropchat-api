import { assertEquals } from "jsr:@std/assert";
import { fromFileUrl, join } from "jsr:@std/path";

// The project ref is a fact about WHICH Supabase project this repo talks to,
// and it is spelled in prose far more often than in code: base URLs in
// README and INTEGRATING, the `host` of openapi.json, the curl recipes in
// CLAUDE.md, the plugin's built-in default. Every one of those is a place an
// integrator (or a future session) copies from.
//
// Nothing linked those spellings to the project the CLI is actually pointed
// at, so when the project changed they stayed behind, pointing at a ref that
// still resolves — a live, different project. A wrong ref does not fail
// loudly; it answers 401, and the reader concludes their key is bad.
//
// This test is the link: `[remotes.production].project_id` in config.toml is
// the single declaration, and no file may name a different one.

const ROOT = fromFileUrl(new URL("../../../", import.meta.url));

const SKIP_DIRS = new Set([
  ".git",
  "node_modules",
  "coverage",
  "dist",
  "build",
  ".temp",
]);

const SCANNED = new Set([
  ".md",
  ".ts",
  ".tsx",
  ".js",
  ".mjs",
  ".json",
  ".toml",
  ".yml",
  ".yaml",
  ".sql",
  ".sh",
]);

// A Supabase ref is twenty lowercase letters. Matched only where it is
// unambiguously one — as a hostname, or as the argument of the flag and the
// variables we use to pass it — so an ordinary twenty-letter word in prose
// cannot trip the gate.
const PATTERNS = [
  /\b([a-z]{20})\.supabase\.(?:co|in)\b/g,
  /--project-ref[= ]([a-z]{20})\b/g,
  /\bREF="([a-z]{20})"/g,
  /\bproject_id\s*=\s*"([a-z]{20})"/g,
  /\bproject[-_]?ref["'\s:=]+([a-z]{20})\b/gi,
];

function declaredRef(): string {
  const toml = Deno.readTextFileSync(join(ROOT, "supabase", "config.toml"));
  const production = toml.split(/^\[remotes\.production\]$/m)[1];

  if (!production) {
    throw new Error("config.toml has no [remotes.production] block");
  }

  const match = production.match(/^project_id\s*=\s*"([a-z]{20})"/m);

  if (!match) {
    throw new Error("[remotes.production] declares no project_id");
  }

  return match[1];
}

function* walk(dir: string): Generator<string> {
  for (const entry of Deno.readDirSync(dir)) {
    if (entry.name.startsWith(".") && entry.name !== ".github") continue;
    if (SKIP_DIRS.has(entry.name)) continue;

    const path = join(dir, entry.name);

    if (entry.isDirectory) {
      yield* walk(path);
    } else if (SCANNED.has(entry.name.slice(entry.name.lastIndexOf(".")))) {
      yield path;
    }
  }
}

Deno.test("every project ref in the repo is the one we declare", () => {
  const expected = declaredRef();
  const here = fromFileUrl(import.meta.url);
  const strays: string[] = [];

  for (const path of walk(ROOT)) {
    if (path === here) continue;

    const text = Deno.readTextFileSync(path);

    for (const pattern of PATTERNS) {
      for (const hit of text.matchAll(pattern)) {
        if (hit[1] === expected) continue;

        const line = text.slice(0, hit.index).split("\n").length;

        strays.push(`${path.slice(ROOT.length)}:${line}: ${hit[1]}`);
      }
    }
  }

  assertEquals(
    strays.sort(),
    [],
    `these name a project that is not ${expected}:\n${
      strays.sort().join("\n")
    }`,
  );
});
