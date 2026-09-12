import json,sys
from pathlib import Path
a=Path(sys.argv[1]); old=json.loads((a/'old-connections.json').read_text()); state=json.loads((a/'ap2-state.json').read_text()); db=json.loads((a/'db-capacity.json').read_text()); continuity=json.loads((a/'db-continuity.json').read_text()); cleanup=json.loads((a/'cleanup.json').read_text())
assert old['matched_count']==10 and len(old['pg_rows'])==10
assert state['accepted']==12 and state['connected']>=1 and state['failed']>=1 and state['connected']+state['failed']==12
assert db['max_connections']==20 and db['superuser_reserved_connections']==3
assert db['ap_server_1']==10 and db['ap_server_2']==state['connected'] and db['management']==2
assert db['numbackends']>=db['ap_server_1']+db['ap_server_2']+db['management']+1
assert 0<db['numbackends']<=db['max_connections']
assert continuity['unchanged'] is True and cleanup['verified'] is True
log=(a/'db.log').read_text(errors='replace').lower()
assert 'fatal:' in log and ('too many clients already' in log or 'remaining connection slots are reserved' in log)
