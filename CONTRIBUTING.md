# Contributing

Thanks for your interest in contributing to OpenBSP API!

## Local Setup

Requires Node, Docker, and
[Deno](https://docs.deno.com/runtime/getting_started/installation/) (used by the
Edge Functions and the CI checks).

1. Clone the repo:
   ```bash
   git clone https://github.com/matiasbattocchia/open-bsp-api
   cd open-bsp-api
   ```

2. Start the local Supabase instance:
   ```bash
   npx supabase start
   ```

3. Serve Edge Functions locally:
   ```bash
   npx supabase functions serve
   ```

## Database Changes

- Edit schema files in `supabase/schemas/` (never create tables directly via
  SQL)
- Generate a migration: `npx supabase db diff -f <migration_name>`
- Indexes on large tables (`messages`, `conversations`): hand-edit the generated
  `CREATE INDEX` into `CREATE INDEX CONCURRENTLY`. The CLI applies each
  migration statement outside a transaction block, so it works; a plain
  `CREATE INDEX` blocks writes for the whole build.
- Apply it locally: `npx supabase migration up`
- Regenerate types:
  `npx supabase gen types typescript --local > supabase/functions/_shared/db_types.ts`
- Any change to a policy, a helper or a trigger comes with a pgTAP test in
  `supabase/tests/database/` (see `supabase/tests/run.sh`).

## Tests

```bash
# Database (pgTAP): loads supabase/tests/fixtures/seed_test.sql, then runs
# every *.test.sql under supabase/tests/database against the local database.
supabase/tests/run.sh          # add --reset to `supabase db reset` first

# Edge Functions (Deno.test); the ones that need the database skip themselves
# when no local Supabase answers.
cd supabase/functions && deno task test:coverage
```

## Code Checks

CI runs `.github/workflows/check.yml` on every push and pull request. Run the
same checks locally before pushing so they pass:

```bash
# 1. Format the whole repo (CI runs `deno fmt --check`)
deno fmt

# 2. Lint and type-check the Edge Functions
cd supabase/functions && deno lint && deno check . && cd ../..

# 3. Lint and type-check the plugin
cd plugin && deno lint && deno check . && cd ..
```

`deno fmt` formats in place; CI only verifies (`deno fmt --check`), so a commit
with unformatted files — including Markdown such as `README.md` or the docs in
the repo root — will fail the check. Run `deno fmt --check` to preview what
would fail without changing any files.

## Submitting Changes

1. Fork the repo and create a branch from `develop`
2. Make your changes
3. Run the [code checks](#code-checks) and the [tests](#tests) and ensure they
   pass
4. Open a pull request against `develop` with a clear description

## Branches and deployment

`develop` deploys to the DEV project and `main` to production, both through the
Supabase GitHub integration on every push. `main` only ever receives `develop`:
a pull request from any other branch into `main` fails the `promotion` job in
`check.yml`. Promote by opening a pull request `develop → main` after the DEV
deploy has been smoke-tested. Protect `main` in the repository settings (require
the `check` and `promotion` checks, no direct pushes) so the gate cannot be
skipped.

PRs are welcome for bug fixes, new tools, protocol support, and documentation.
