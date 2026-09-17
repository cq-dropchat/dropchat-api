// Fails when the lcov report is under the line-coverage threshold. `deno
// coverage` prints a table but has no gate of its own; CI needs one.
//
//   deno run --allow-read _shared/testing/coverage_gate.ts coverage/lcov.info [--min-lines N]
//
// Thresholds are ratcheted at the end of each phase and never lowered. See
// IMPLEMENTATION_STATUS.md.
//
// Three gates, because one number over "everything the tests loaded" is not
// stable: `deno coverage` only counts modules a test imported, so the first
// test of a 1,000-line handler moves the global figure by tens of points.
// The layers of the audit prompt are gated separately — `_shared/*` (pure
// modules, mappers, helpers) and the handlers (every other file) — plus the
// global figure, which is what CI reports.
//
//   --min-shared N     lines % over files under _shared/   (default below)
//   --min-handlers N   lines % over every other file
//   --min-lines N      lines % over all files

// Ratchet (end of phase 3): reached − 2, rounded down. Reached: _shared
// 68.9 %, handlers 31.8 %, all 37.8 %. Never lowered.
const DEFAULT_MIN_SHARED = 66;
const DEFAULT_MIN_HANDLERS = 29;
const DEFAULT_MIN_LINES = 35;

type Totals = { found: number; hit: number };

function pct(t: Totals) {
  return t.found === 0 ? 0 : (t.hit / t.found) * 100;
}

function parseLcov(text: string) {
  const all: Totals = { found: 0, hit: 0 };
  const shared: Totals = { found: 0, hit: 0 };
  const handlers: Totals = { found: 0, hit: 0 };
  const perFile: { file: string; found: number; hit: number }[] = [];
  let current: { file: string; found: number; hit: number } | null = null;

  for (const line of text.split("\n")) {
    if (line.startsWith("SF:")) {
      current = { file: line.slice(3), found: 0, hit: 0 };
    } else if (line.startsWith("LF:") && current) {
      current.found = Number(line.slice(3));
    } else if (line.startsWith("LH:") && current) {
      current.hit = Number(line.slice(3));
    } else if (line === "end_of_record" && current) {
      const layer = current.file.includes("/_shared/") ? shared : handlers;
      layer.found += current.found;
      layer.hit += current.hit;
      all.found += current.found;
      all.hit += current.hit;
      perFile.push(current);
      current = null;
    }
  }

  return { all, shared, handlers, perFile };
}

function arg(args: string[], name: string, fallback: number): number {
  const i = args.indexOf(name);
  return i >= 0 ? Number(args[i + 1]) : fallback;
}

if (import.meta.main) {
  const [path, ...rest] = Deno.args;

  if (!path) {
    console.error(
      "usage: coverage_gate.ts <lcov.info> [--min-lines N] [--min-shared N] [--min-handlers N]",
    );
    Deno.exit(2);
  }

  const { all, shared, handlers } = parseLcov(await Deno.readTextFile(path));
  const gates = [
    {
      name: "_shared",
      totals: shared,
      min: arg(rest, "--min-shared", DEFAULT_MIN_SHARED),
    },
    {
      name: "handlers",
      totals: handlers,
      min: arg(rest, "--min-handlers", DEFAULT_MIN_HANDLERS),
    },
    {
      name: "all",
      totals: all,
      min: arg(rest, "--min-lines", DEFAULT_MIN_LINES),
    },
  ];

  let failed = false;

  for (const gate of gates) {
    const p = pct(gate.totals);
    const ok = p >= gate.min;
    console.log(
      `${gate.name.padEnd(9)} lines ${gate.totals.hit}/${gate.totals.found} = ${
        p.toFixed(2)
      }% (threshold ${gate.min}%)${ok ? "" : "  ← FAILED"}`,
    );
    if (!ok) failed = true;
  }

  if (failed) {
    console.error("coverage gate FAILED");
    Deno.exit(1);
  }
}

export { parseLcov };
