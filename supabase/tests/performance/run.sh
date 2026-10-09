#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
mkdir -p artifacts/performance
# No target URL override: synthetic writes only against the disposable local DB.
if [[ -n "${SQL_DOCKER_CONTAINER:-}" ]]; then
  SQL=(docker exec -i "$SQL_DOCKER_CONTAINER" psql -U postgres -d postgres)
else
  SQL=(psql postgresql://postgres:postgres@127.0.0.1:54322/postgres)
fi
python3 - <<'MANIFEST' > artifacts/performance/manifest.json
import json, platform, subprocess, os
from pathlib import Path
def command(args):
    try:
        p=subprocess.run(args,capture_output=True,text=True)
        return p.stdout.strip() if p.returncode==0 else 'unavailable'
    except OSError:
        return 'unavailable'
print(json.dumps({'sha':command(['git','rev-parse','HEAD']), 'platform':platform.platform(),
 'cpu_count':os.cpu_count(),'deno':command([os.getenv('DENO_BIN','deno'),'--version']),
 'dirty':bool(command(['git','status','--porcelain'])),
 'diff_sha256':__import__('hashlib').sha256(command(['git','diff','HEAD']).encode()).hexdigest(),
 'supabase':command(['supabase','--version']),
 'runner':os.getenv('RUNNER_NAME','local'),
 'memory':command(['sh','-c','cat /proc/meminfo 2>/dev/null || sysctl hw.memsize']),
 'images':command(['docker','ps','--format','{{.Names}} {{.Image}}'])},indent=2))
MANIFEST
"${SQL[@]}" -At -v ON_ERROR_STOP=1 -c "select json_build_object('postgres',version(),'extensions',(select json_agg(row_to_json(e)) from (select extname,extversion from pg_extension) e));" > artifacts/performance/database.json
set +e
"${SQL[@]}" -qAt -v ON_ERROR_STOP=1 < supabase/tests/performance/init_window.sql > artifacts/performance/profiles.jsonl 2> artifacts/performance/sql.stderr
status=$?
set -e
cat artifacts/performance/sql.stderr
# Persist ALL role/scenario reports before evaluating correctness and cost.
python3 - <<'GATE'
import json
from pathlib import Path
p=Path('artifacts/performance')
reports=[json.loads(line) for line in (p/'profiles.jsonl').read_text().splitlines() if line.startswith('{')]
for i,report in enumerate(reports):
    (p/f"{report['distribution']}-{report['actor']}.json").write_text(json.dumps(report,indent=2)+'\n')
    print(f"{report['distribution']} {report['effective_role']} {report['actor']}: correct={report['correct']} buffers={report['buffers']}/{report['max_buffers']} ms={report['execution_ms']}")
assert len(reports)==8, f'Expected 8 role/scenario reports, got {len(reports)}; inspect sql.stderr'
assert all(r['correct'] and r['passed'] for r in reports), 'SQL correctness/performance gate failed; inspect artifacts'
GATE
exit "$status"
