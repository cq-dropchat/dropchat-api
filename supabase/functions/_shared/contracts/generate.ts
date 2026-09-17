// F29. The versioned contract of `messages.content`, generated from the
// types the Edge Functions compile against (_shared/types/message_types.ts).
//
//   deno run -A _shared/contracts/generate.ts          writes the schema
//   deno run -A _shared/contracts/generate.ts --check  fails if it is stale
//
// The committed file is what integrators read (contracts/ at the repository
// root); contract.test.ts fails CI when a type change was not regenerated.
import { createGenerator } from "npm:ts-json-schema-generator@2.4.0";
import { fromFileUrl } from "jsr:@std/path@1";

export const SCHEMA_PATH = fromFileUrl(
  new URL(
    "../../../../contracts/message-content.v1.schema.json",
    import.meta.url,
  ),
);

export function generateContentSchema(): string {
  const entry = fromFileUrl(new URL("./content_v1.ts", import.meta.url));
  const schema = createGenerator({
    path: entry,
    type: "MessageContentV1",
    tsconfig: fromFileUrl(new URL("./tsconfig.json", import.meta.url)),
    skipTypeCheck: true,
    additionalProperties: true,
    sortProps: true,
    expose: "export",
    topRef: true,
  }).createSchema("MessageContentV1");

  return JSON.stringify(
    {
      $id: "https://openbsp.dev/contracts/message-content.v1.schema.json",
      title: "OpenBSP message content, version 1",
      description:
        'The `content` column of public.messages for rows with version "1". Generated from supabase/functions/_shared/types/message_types.ts; do not edit by hand.',
      ...schema,
    },
    null,
    2,
  ) + "\n";
}

if (import.meta.main) {
  const generated = generateContentSchema();
  if (Deno.args.includes("--check")) {
    const committed = await Deno.readTextFile(SCHEMA_PATH).catch(() => "");
    if (committed !== generated) {
      console.error(
        "contracts/message-content.v1.schema.json is stale: run deno task contracts",
      );
      Deno.exit(1);
    }
  } else {
    await Deno.writeTextFile(SCHEMA_PATH, generated);
    console.log(`wrote ${SCHEMA_PATH}`);
  }
}
