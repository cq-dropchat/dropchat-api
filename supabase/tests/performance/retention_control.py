#!/usr/bin/env python3
# Controlled opt-in rehearsal; ALWAYS rolled back, never alters policy permanently.
import json,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[3]
preview=(root/'supabase/tests/performance/retention_snapshot.sql').read_text().replace('begin read only;','').replace('rollback;','')
fixture="""
begin;
update public.organizations set extra=jsonb_set(coalesce(extra,'{}'),'{queue_retention}','{"success_days":30,"failure_days":90}') where id=tests.id('org_a');
update public.organizations set extra=jsonb_set(coalesce(extra,'{}'),'{queue_retention}','{"success_days":0,"failure_days":"invalid"}') where id=tests.id('org_b');
insert into public.edge_calls(organization_id,function,record_id,payload,status,updated_at)
select org,'agent-client',gen_random_uuid(),'{}',state,now()-interval '100 days'
from unnest(array[tests.id('org_a'),tests.id('org_b')]) org cross join unnest(array['done','failed','pending','sending']) state;
"""
verify="""
select jsonb_build_object('purged',public.purge_expired_rows(10000),'protected',
(select count(*) from public.edge_calls where updated_at<now()-interval '99 days' and (status in ('pending','sending') or organization_id=tests.id('org_b'))));
rollback;
"""
p=subprocess.run(['docker','exec','-i','supabase_db_open-bsp-api','psql','-U','postgres','-d','postgres','-qAt','-v','ON_ERROR_STOP=1'],input=fixture+preview+verify,text=True,capture_output=True)
if p.returncode:raise RuntimeError(p.stderr)
reports=[json.loads(line) for line in p.stdout.splitlines() if line.startswith('{')]
assert len(reports)==2
count=sum(row['candidates'] for row in reports[0]['candidates'] if row['table_name']=='edge_calls')
assert count==reports[1]['purged']['edge_calls']==2,reports
assert reports[1]['protected']==6,reports
out=root/'artifacts/retention';out.mkdir(parents=True,exist_ok=True)
(out/'controlled.json').write_text(json.dumps({'qualification':'local rollback; no production policy enabled','preview':reports[0],'actual':reports[1]},indent=2)+'\n')
print('preview=2; purged=2; six old pending/inflight/invalid-policy rows protected; rollback')
