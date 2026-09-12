import json
import pathlib
import sys

art = pathlib.Path(sys.argv[1])
summary = json.loads((art / 'recovery.json').read_text(encoding='utf-8'))
state = json.loads((art / 'failover-state.json').read_text(encoding='utf-8'))
outcomes = json.loads((art / 'termination.json').read_text(encoding='utf-8'))
cleanup = json.loads((art / 'cleanup.json').read_text(encoding='utf-8'))
assert state['status'] == 'ACTIVE' and state['active_service'] == 'ap-server-2'
assert len(outcomes) == 10 and all(x['status'] in ('terminated', 'missing') for x in outcomes)
assert summary['before_old'] == 10 and summary['after_old'] == 0
assert 1 <= summary['before_new'] == summary['after_new'] <= 5
assert summary['new_failures'] >= 1
assert summary['before_management'] == summary['after_management'] == 2
assert summary['new_pids_preserved'] and summary['management_pids_preserved']
assert summary['business_committed'] and summary['db_unchanged']
assert cleanup['verified'] is True
