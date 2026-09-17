#!/usr/bin/env bash
#
# Runs the pgTAP suite against the local Supabase database.
#
#   supabase/tests/run.sh            load fixture, run tests
#   supabase/tests/run.sh --reset    `supabase db reset` first (fresh schema + seed)
#
# The fixture lives OUTSIDE the directory handed to pg_prove on purpose:
# `supabase test db` recurses into every *.sql under supabase/tests, and the
# fixture is data, not a test. It is loaded once with psql and committed; every
# test file then runs inside its own BEGIN/ROLLBACK.
set -euo pipefail

cd "$(dirname "$0")/../.."

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

if [ "${1:-}" = "--reset" ]; then
  npx supabase db reset
fi

psql "$DB_URL" -v ON_ERROR_STOP=1 -q -f supabase/tests/fixtures/seed_test.sql

npx supabase test db supabase/tests/database
