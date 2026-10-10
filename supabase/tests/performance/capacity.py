#!/usr/bin/env python3
"""Disposable local PostgreSQL only. Real triggers, scheduler, commits and rollback.
No edge runtime may be running. Writes never target a configurable remote URL.
"""
import json, pathlib, subprocess, time, threading
ROOT=pathlib.Path(__file__).resolve().parents[3]
OUT=ROOT/'artifacts/capacity';OUT.mkdir(parents=True,exist_ok=True)
CONTAINER='supabase_db_open-bsp-api'
def sql(text):
 p=subprocess.run(['docker','exec','-i',CONTAINER,'psql','-U','postgres','-d','postgres','-qAt','-v','ON_ERROR_STOP=1'],input=text,text=True,capture_output=True)
 if p.returncode: raise RuntimeError(p.stderr)
 return p.stdout.strip()
def metric():
 return json.loads(sql("select json_build_object('wal',pg_current_wal_lsn()::text,'deadlocks',(select deadlocks from pg_stat_database where datname=current_database()),'locks',(select count(*) from pg_stat_activity where datname=current_database() and wait_event_type='Lock'))"))
images=subprocess.check_output(['docker','ps','--format','{{.Names}} {{.Image}}'],text=True)
if 'supabase_edge_runtime_open-bsp-api' in images: raise RuntimeError('Exclude edge-runtime before generating armed messages')
(OUT/'manifest.json').write_text(json.dumps({'images':images,'qualification':'local synthetic; no provider throughput','offered_rate':None,'peak_observed':None},indent=2))
for volume in [1000,100000,1000000]:
 report=sql((ROOT/'supabase/tests/performance/queue_capacity.sql').read_text().replace(':volume',str(volume)))
 (OUT/f'queue-{volume}.json').write_text(report+'\n');print('queue',volume,flush=True)
setup="""
insert into public.organizations(id,name) select ('e4000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'billing-capacity-'||n from generate_series(1,8)n on conflict do nothing;
insert into public.organizations_addresses(organization_id,service,address) select ('e4000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'whatsapp','capacity-'||n from generate_series(1,8)n on conflict do nothing;
insert into public.agents(id,organization_id,user_id,name,role) select ('e4000000-0000-4000-8001-'||lpad(n::text,12,'0'))::uuid,('e4000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'aaaaaaaa-0000-4000-8000-0000000000a1'::uuid,'capacity-human','owner' from generate_series(1,8)n on conflict do nothing;
"""
sql(setup)
for tenants in [1,8]:
 for clients in [1,4,16]:
  for mode in ['write','rollback']:
   # One scenario starts from zero usage; deletes execute the real inverse trigger.
   sql("delete from public.messages where organization_id::text like 'e4000000-%';")
   file=ROOT/f'supabase/tests/performance/billing_{mode}.sql'
   subprocess.run(['docker','cp',str(file),f'{CONTAINER}:/tmp/billing.sql'],check=True,capture_output=True)
   baseline=json.loads(sql("select json_agg(t) from (select interval,sum(quantity) as quantity from billing.usage where organization_id::text like 'e4000000-%' and product_id='messages' group by interval order by interval)t")) or []
   before=metric();samples=[];stop=threading.Event()
   def monitor():
    while not stop.wait(.05): samples.append(metric()['locks'])
   thread=threading.Thread(target=monitor);thread.start()
   started=time.monotonic()
   try:
    run=subprocess.run(['docker','exec',CONTAINER,'pgbench','-U','postgres','-d','postgres','-n','-c',str(clients),'-j',str(clients),'-t','20','-D',f'tenants={tenants}','-f','/tmp/billing.sql','-l','--log-prefix',f'/tmp/bill-{tenants}-{clients}-{mode}'],text=True,capture_output=True)
   finally: stop.set();thread.join()
   after=metric()
   if run.returncode: raise RuntimeError(run.stdout+run.stderr)
   logs=subprocess.check_output(['docker','exec',CONTAINER,'sh','-c',f'cat /tmp/bill-{tenants}-{clients}-{mode}.*'],text=True)
   durations=sorted(int(line.split()[2])/1000 for line in logs.splitlines() if line.strip())
   expected=clients*20 if mode=='write' else 0
   count=int(sql("select count(*) from public.messages where organization_id::text like 'e4000000-%'"))
   usage=json.loads(sql("select json_agg(t) from (select interval,sum(quantity) as quantity from billing.usage where organization_id::text like 'e4000000-%' and product_id='messages' group by interval order by interval)t"))
   assert count==expected and all(float(row['quantity'])-next((float(b['quantity']) for b in baseline if b['interval']==row['interval']),0)==expected for row in usage),(count,usage,baseline,expected)
   wal=int(sql(f"select pg_wal_lsn_diff('{after['wal']}', '{before['wal']}')"))
   report={'tenants':tenants,'writers':clients,'mode':mode,'transactions':clients*20,'rows':count,'usage':usage,'baseline_usage':baseline,'p95_transaction_ms':durations[max(0,int(len(durations)*.95+.999)-1)],'elapsed_s':time.monotonic()-started,'max_observed_lock_waiters':max(samples,default=0),'lock_samples':len(samples),'deadlocks_delta':after['deadlocks']-before['deadlocks'],'wal_bytes_cluster':wal,'pgbench':run.stdout,'qualification':'commit transaction latency includes insert and triggers; WAL is cluster-wide, no isolated commit-only timer'}
   (OUT/f'billing-{tenants}-{clients}-{mode}.json').write_text(json.dumps(report,indent=2)+'\n')
   print('billing',tenants,clients,mode,report['p95_transaction_ms'],flush=True)
sql("delete from public.messages where organization_id::text like 'e4000000-%';")
