# CLAUDE.md

## Project overview

Open BSP API — a multi-tenant WhatsApp Business Platform integration built with
Deno, Postgres, and Supabase Edge Functions. See README.md for full details.

## Local checks must match CI (deno)

CI (`.github/workflows/check.yml`) runs:

```bash
deno fmt --check
cd supabase/functions && deno lint && deno check .
cd plugin && deno lint && deno check .
```

**`deno check` only works from inside the package dir.** Run
`cd supabase/functions && deno check .` — NOT `deno check <file>` from the repo
root. The import map lives in `supabase/functions/deno.json` (there is no root
`deno.json`), so checking a file from the root resolves no bare specifiers and
prints **false** `Import "@supabase/supabase-js" not a dependency` /
`"ky"`/`"zod"`/`"postgres"` errors. These are an artifact of the wrong CWD, not
real errors — don't treat them as a pre-existing baseline.

> The `.claude/settings.json` PostToolUse hook runs `deno check <file>` without
> `cd` and swallows output with `|| true`, so it always "passes" for functions
> files and verifies nothing there. Run the CI command yourself to actually
> verify.

**`deno fmt` output is deno-version-dependent.** The repo pins fmt _config_
(lineWidth 80, semicolons, double quotes) but not the deno _binary_ (CI uses
`v2.x`). A different local deno can report spurious diffs on generated files
(e.g. `_shared/db_types.ts`). Only format files you actually changed; never
reformat the whole tree to chase a version-difference diff.

## Debugging production edge functions

### Timestamps

The current date/time is NOT reliably in the conversation context. When querying
logs with time ranges (e.g., "last 12 hours"), **always run `date -u` first** to
get the actual current UTC time. Do not guess or hardcode timestamps.

### Querying stdout logs (console.log / console.error)

Use the Supabase Management API to query `function_logs` (edge function stdout):

```bash
ACCESS_TOKEN=$(cat ~/.supabase/access-token)
REF="qqfrzurledgywyhcxdse"

curl -s "https://api.supabase.com/v1/projects/${REF}/analytics/endpoints/logs.all" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -G \
  --data-urlencode "sql=select cast(timestamp as datetime) as ts, event_message from function_logs where regexp_contains(event_message, 'ERROR_KEYWORD') order by timestamp desc limit 10" \
  --data-urlencode "iso_timestamp_start=2026-04-10T00:00:00Z"
```

Log lines are JSON (`_shared/logger.ts`): `ts`, `level`, `fn`, `request_id`,
`msg`, plus the details' fields (`organization_id`, `message_id`, …). Every
response carries `x-request-id`; filter one invocation with
`regexp_contains(event_message, '"request_id":"<id>"')`, or one message with
`'"message_id":"<uuid>"'`.

A request id also follows a message across functions (F26): the Supabase clients
send it to PostgREST as `x-request-id`, and the triggers that call the next
function forward it (`public.request_id_header()`). One inbound WhatsApp
message, the agent reply and its dispatch share the webhook's id, so the whole
chain is one query:

```sql
select cast(timestamp as datetime) as ts,
       json_value(event_message, '$.fn') as fn,
       json_value(event_message, '$.msg') as msg,
       event_message
from function_logs
where regexp_contains(event_message, '"request_id":"<id>"')
order by timestamp asc
limit 1000
```

Take `<id>` from the response's `x-request-id` or from any line of the chain
(e.g. find the dispatcher's line by `message_id`, then query its `request_id`).
Chains started by cron (the dispatch sweep, retries) have no incoming id: each
sweep request mints its own. The id is internal: it is not sent to agent tools,
Meta, Slack or Instagram.

Available log tables: `function_logs` (stdout), `function_edge_logs`
(HTTP-level), `edge_logs`, `postgres_logs`, `auth_logs`, `storage_logs`,
`realtime_logs`. Uses BigQuery SQL syntax. Max 1000 rows per query. Always
filter by timestamp.

### Edge call queue (agent-client, media-preprocessor)

Since F12 the message triggers do not call these two functions with pg_net: they
insert into `public.edge_calls`, and the `deliver-edge-calls` pg_cron job (every
5 seconds) settles attempts from `net._http_response` and sends what is due —
round-robin across organizations, retries with backoff (5 s, 30 s, 2 min, 10
min), `failed` after 5 attempts or on a non-retryable 4xx. A pg_net timeout
counts as done: the function keeps running after pg_net stops waiting.

Since P5 the safety net queues too. `sweep-pending-media` (every minute) runs
`public.sweep_pending_media()`, which enqueues a `media-preprocessor` call for
every armed file message that is still not preprocessed and whose claim is
absent or older than ten minutes — skipping any message that already has a call
pending or in flight, so the sweep and the trigger cannot queue the same message
twice. It replaces `preprocess-pending-messages`, which posted to the function
with pg_net directly; that job no longer exists. So `edge_calls` is now the only
way either function is invoked, and the queue's metric covers retries as well as
first attempts.

```sql
-- Backlog per function and organization (alert: pending growing, or
-- oldest_pending_at more than a minute old)
select * from public.edge_calls_health order by pending desc;

-- What the media sweep would pick up right now (it queues at most 500 a run)
select count(*) from public.messages
where timestamp >= now() - interval '12 hours'
  and timestamp <= now() - interval '1 minute'
  and content ->> 'type' = 'file'
  and status ->> 'pending' is not null
  and status ->> 'preprocessed' is null;

-- Why calls fail
select function, last_status_code, last_error, count(*)
from public.edge_calls
where status = 'failed' and updated_at > now() - interval '1 day'
group by 1, 2, 3 order by 4 desc;
```

Runbook for the production rollout of `…_f12_edge_calls.sql`:

1. Before: note `select count(*) from net.http_request_queue` and the p95 of
   agent-client replies.
2. Apply the migration (CI). It creates the table, replaces the two triggers in
   place and schedules `deliver-edge-calls`.
3. Verify within a minute: `select * from public.edge_calls_health` shows
   `pending` near 0 and `last_done_at` advancing;
   `select * from cron.job_run_details where jobid = (select jobid from cron.job
   where jobname = 'deliver-edge-calls') order by start_time desc limit 5`
   succeeds.
4. Latency: measured locally, insert → request p50 2.6–3.1 s / p95 4.9–6.6 s
   with the 5-second job (pg_net direct: 0.5 s / 1.0 s). If that is too slow,
   `select cron.alter_job((select jobid from cron.job where jobname =
   'deliver-edge-calls'), schedule := '1 seconds')`
   measured 0.7 s / 1.2 s (at the cost of ~86k `cron.job_run_details` rows a
   day).
5. Rollback: a migration that points `handle_incoming_message_to_agent` and
   `handle_message_to_media_preprocessor` back at
   `public.edge_function('/agent-client' | '/media-preprocessor', 'post')` and
   restores `local_message_to_agent`'s `net.http_post` (see
   `20260917163830_f26_forward_request_id.sql` for the previous bodies); keep
   `deliver-edge-calls` scheduled until `edge_calls_health` shows nothing
   pending, then unschedule it. A rollback of P5 also restores
   `preprocess-pending-messages` (body in
   `20260129131456_annotator_refactor_to_media_preprocessor.sql`) and
   unschedules `sweep-pending-media`.
6. Interval, once there is traffic: watch `edge_calls_health` and the agent's
   p95 for a week before touching the 5-second job. Locally, insert → request
   went from 0.5 s / 1.0 s (pg_net straight from the trigger) to 2.6–3.1 s /
   4.9–6.6 s at 5 seconds, and 0.7 s / 1.2 s at 1 second — at ~86k
   `cron.job_run_details` rows a day. Media preprocessing now pays that same
   queue latency; it did not before P5.

### Querying HTTP-level logs (status codes, execution time)

Use the Supabase MCP server `get_logs` tool with `service: "edge-function"`.
This returns invocation metadata (status code, execution time, function version)
but **not** stdout content.

### Applying database fixes

1. Edit the schema file under `supabase/schemas/`
2. Generate migration: `npx supabase db diff -f <migration_name>`
3. Apply locally: `npx supabase migration up --local` (test before committing)
4. Commit — the user pushes and CI deploys automatically

### Application-level error logs

The `public.logs` table stores application-level errors written by edge
functions (e.g., webhook errors from Meta). Query with:

```sql
SELECT level, category, message, metadata, created_at
FROM public.logs
WHERE level = 'error' AND created_at > now() - interval '24 hours'
ORDER BY created_at DESC;
```

## Database migrations

- Never modify applied migrations. Always create new ones.
- Migrations are **generated** from schema diffs, not manually written: edit the
  schema files under `supabase/schemas/`, then run
  `npx supabase db diff -f <migration_name>`.
- **Never hand-create or hand-edit a migration** except for a few exceptional
  cases that `db diff` can't produce:
  - **Trim spurious `revoke` noise** — `db diff` emits ~144
    `revoke ... from
    anon|authenticated|service_role` lines every run (a
    migra/Supabase default-privilege artifact). Delete them; keep only your real
    changes.
  - **DML / data backfills** — `db diff` emits schema DDL only. Hand-write data
    updates (e.g. backfilling a new column on existing rows).
  - **Imperative bits db diff can't model** — e.g. `cron.schedule(...)` /
    pg_cron jobs (see `*_cron.sql` migrations).
  - **`CREATE INDEX CONCURRENTLY`** — on large tables (`messages`,
    `conversations`) edit the generated `CREATE INDEX` into
    `CREATE INDEX CONCURRENTLY`. It must be the **first statement of the
    migration file**: `supabase db push` (and the GitHub integration) send the
    rest of the file as one pipeline, and a `CONCURRENTLY` there fails with
    _"cannot be executed within a pipeline"_ (SQLSTATE 25001) and rolls the
    whole migration back. If the index cannot go first, put it in its own
    migration. Keep it before any statement that depends on the index (e.g.
    dropping the constraint it replaces).
  - **Enum value additions** — for an enum used by a column that an RLS policy
    (or other dependent) references, `db diff`'s rename/recreate/recast fails to
    apply: _"cannot alter type of a column used in a policy definition"_. Still
    add the value to the enum in `supabase/schemas/01_types.sql`, but replace
    the generated recast with hand-written
    `alter type public.<enum> add value if not
    exists '<v>';` (appends in
    place, touches no columns/policies). The recast is only safe when nothing
    references the column (e.g. `webhook_table`).

  Everything else (columns, policies, triggers, functions) must come from
  editing `supabase/schemas/` and re-running `db diff` — don't append DDL by
  hand.
- Migrations apply automatically via CI: pushing to `origin/develop` deploys to
  DEV, pushing to `origin/main` deploys to PROD. Never apply migrations manually
  or execute DDL directly on production.
- Every change to a policy, helper or trigger ships with a pgTAP test under
  `supabase/tests/database/` (run `supabase/tests/run.sh`); Edge Function
  changes with a `Deno.test` (`cd supabase/functions && deno task test`).
- See README.md "Local development > Database" for the full workflow.

## Generated types

`supabase/functions/_shared/db_types.ts` is **autogenerated** — never hand-edit
it. Regenerate it from the local database after applying a migration:

```bash
npx supabase gen types typescript --local > supabase/functions/_shared/db_types.ts
```

The UI repo mirrors this file at `open-bsp-ui/src/supabase/db_types.ts` — copy
it over after regenerating. See README.md "Local development > Database".
