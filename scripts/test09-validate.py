import json
import pathlib
import sys

art = pathlib.Path(sys.argv[1])
data = json.loads((art / 'identification.json').read_text(encoding='utf-8'))
state = json.loads((art / 'failover-state.json').read_text(encoding='utf-8'))
cleanup = json.loads((art / 'cleanup.json').read_text(encoding='utf-8'))
assert state['status'] == 'ACTIVE' and state['active_service'] == 'ap-server-2'
assert data['postmaster_unchanged'] is True
assert data['ap1_paused'] is True and data['ap2_healthy'] is True
assert data['before_ap1'] == 3 and data['after_ap1'] == 3
assert data['after_ap2'] == 3 and data['after_management'] == 2
assert data['old_pids_preserved'] is True
assert data['old_backends_preserved'] is True
assert data['all_addresses_match'] is True
assert data['all_required_fields_present'] is True
assert cleanup['verified'] is True
