import json,sys
from pathlib import Path
art=Path(sys.argv[1]); before=json.loads((art/'before.json').read_text())
identity=lambda row:(row['pid'],row['backend_start'],row['client_addr'],row['client_port'])
tuples=lambda doc:{(x['db_addr'],x['db_port'],x['client_addr'],x['client_port']) for x in doc['tcp_tuples']}
before_rows={identity(x) for x in before['pg_rows']}; before_tuples=tuples(before)
assert before['matched_count']==12 and len(before_rows)==12 and len(before_tuples)>=12
for name in ('immediate_after','after_5s','after_15s'):
 doc=json.loads((art/f'{name}.json').read_text()); assert doc['matched_count']>=2
 assert before_rows.issubset({identity(x) for x in doc['pg_rows']})
 assert before_tuples.issubset(tuples(doc))
 state=json.loads((art/f'{name}-state.json').read_text()); assert state['ap_paused'] is True
 assert state['postmaster']==json.loads((art/'baseline.json').read_text())['postmaster'] and state['restart_count']==json.loads((art/'baseline.json').read_text())['restart_count']
cleanup=json.loads((art/'connection-cleanup.json').read_text()); assert cleanup['remaining_pids']==[] and cleanup['remaining_tuples']==[] and cleanup['postmaster_unchanged'] is True
actions=[json.loads(x) for x in (art/'cleanup-backend-actions.jsonl').read_text().splitlines() if x]
assert len(actions)==12 and all(x['db_result']['action'] in ('TERMINATED','SKIPPED_GONE') for x in actions)
