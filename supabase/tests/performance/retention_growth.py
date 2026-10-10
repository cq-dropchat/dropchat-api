#!/usr/bin/env python3
"""Compare two read-only snapshots. Activity counters are not committed intake."""
import datetime, json, pathlib, sys
first, second = [json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:3]]
elapsed = (datetime.datetime.fromisoformat(second['observed_at'])-datetime.datetime.fromisoformat(first['observed_at'])).total_seconds()
if elapsed <= 0: raise ValueError('Snapshots must be separated in time')
a = {t['relname']:t for t in first['tables']}
rows=[]
for t in second['tables']:
    before=a.get(t['relname'])
    if not before: continue
    reset = first.get('stats_reset') != second.get('stats_reset') or any(t[k]<before[k] for k in ['n_tup_ins','n_tup_del'])
    rows.append({'table':t['relname'],'elapsed_s':elapsed,'counter_reset':reset,
      'insert_activity_per_day':None if reset else (t['n_tup_ins']-before['n_tup_ins'])*86400/elapsed,
      'delete_activity_per_day':None if reset else (t['n_tup_del']-before['n_tup_del'])*86400/elapsed,
      'estimated_live_delta':t['n_live_tup']-before['n_live_tup'],'dead_rows':t['n_dead_tup'],
      'table_bytes_delta':t['table_bytes']-before['table_bytes'],'index_bytes_delta':t['index_bytes']-before['index_bytes'],
      'physical_table_bytes_per_estimated_live_row':t['table_bytes']/t['n_live_tup'] if t['n_live_tup'] else None,
      'autovacuum_count_delta':None if reset else t['autovacuum_count']-before['autovacuum_count'], 'last_autovacuum':t['last_autovacuum']})
print(json.dumps({'qualification':'local activity only; statistics include attempted/rolled-back writes, live/dead counts are estimates; physical bytes need not shrink after DELETE; not seven representative production days','start':first['observed_at'],'end':second['observed_at'],'tables':rows,'candidates_before':first['candidates'],'candidates_after':second['candidates']},indent=2))
