import json
import sys
from pathlib import Path

artifact = Path(sys.argv[1])
old = json.loads((artifact / 'old-connections.json').read_text())
state = json.loads((artifact / 'ap2-state.json').read_text())
capacity = json.loads((artifact / 'db-capacity.json').read_text())
continuity = json.loads((artifact / 'db-continuity.json').read_text())
cleanup = json.loads((artifact / 'cleanup.json').read_text())
assert old['matched_count'] == 10
assert state['accepted'] == 12 and state['failed'] >= 1
assert state['connected'] + state['failed'] == 12
assert capacity['max_connections'] == 20 and capacity['ap_server_1'] == 10
assert capacity['ap_server_2'] == state['connected']
assert capacity['management'] == 2
assert continuity['unchanged'] is True and cleanup['verified'] is True

messages = ('too many clients already', 'remaining connection slots are reserved')
db_log = (artifact / 'db.log').read_text(errors='replace').lower()
assert any('fatal:' in row.lower() and any(message in row.lower() for message in messages)
           for row in db_log.splitlines())
ap_rows = [json.loads(line) for line in (artifact / 'ap2.log').read_text().splitlines()
           if line.strip().startswith('{')]
failed_ids = {row['request_id'] for row in state['requests']
              if row['state'] == 'CONNECTION_FAILED' and row['error_phase'] == 'connect'}
log_failures = [row for row in ap_rows if row.get('event') == 'CONNECTION_FAILED']
assert len(failed_ids) == state['failed'] and len(log_failures) == state['failed']
assert {row['request_id'] for row in log_failures} == failed_ids
assert all(row['ap'] == 'ap-server-2' and row['error_phase'] == 'connect'
           and row['error_type'] == 'OperationalError'
           and any(message in row['db_error'].lower() for message in messages)
           for row in log_failures)
assert all(any(message in db_log for message in messages if message in row['db_error'].lower())
           for row in log_failures)
