// Fails when the lcov report is under the line-coverage threshold. `deno
// coverage` prints a table but has no gate of its own; CI needs one.
//
//   deno run --allow-read _shared/testing/coverage_gate.ts coverage/lcov.info [--min-lines N]
//
// The threshold is ratcheted at the end of each phase to (reached − 2) and
// never lowered. See IMPLEMENTATION_STATUS.md.

const DEFAULT_MIN_LINES = 20;

function parseLcov(text: string) {
  let found = 0;
  let hit = 0;
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
      found += current.found;
      hit += current.hit;
      perFile.push(current);
      current = null;
    }
  }

  return { found, hit, perFile };
}

if (import.meta.main) {
  const [path, ...rest] = Deno.args;
  const minIndex = rest.indexOf("--min-lines");
  const minLines = minIndex >= 0
    ? Number(rest[minIndex + 1])
    : DEFAULT_MIN_LINES;

  if (!path) {
    console.error("usage: coverage_gate.ts <lcov.info> [--min-lines N]");
    Deno.exit(2);
  }

  const { found, hit } = parseLcov(await Deno.readTextFile(path));
  const pct = found === 0 ? 0 : (hit / found) * 100;

  console.log(
    `lines: ${hit}/${found} = ${pct.toFixed(2)}% (threshold ${minLines}%)`,
  );

  if (pct < minLines) {
    console.error(`coverage gate FAILED: ${pct.toFixed(2)}% < ${minLines}%`);
    Deno.exit(1);
  }
}

export { parseLcov };
