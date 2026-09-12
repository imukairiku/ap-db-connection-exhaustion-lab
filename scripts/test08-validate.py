import datetime,json,sys
from pathlib import Path

art=Path(sys.argv[1]); pointer=json.loads((Path('artifacts/phase3/current.json')).read_text())
state=json.loads((art/'failover-state.json').read_text())
events=[json.loads(line) for line in (art/'monitor-events.jsonl').read_text().splitlines() if line]
ap1=json.loads((art/'ap1-after.json').read_text())[0]
ap1_before=json.loads((art/'ap1-before.json').read_text())[0]
ap2=json.loads((art/'ap2-inspect.json').read_text())[0]
before=json.loads((art/'before.json').read_text())
continuity=json.loads((art/'db-continuity.json').read_text())
cleanup=json.loads((art/'cleanup.json').read_text())
assert pointer['state_path']==str(art/'failover-state.json')
assert pointer['run_id']==state['run_id'] and pointer['project']==state['project']
assert state['status']=='ACTIVE' and state['active_service']=='ap-server-2'
assert state['ap1_container_id']==ap1['Id'] and state['ap2_container_id']==ap2['Id']
assert ap1_before['Id']==ap1['Id'] and ap1_before['State']['Running'] is True
assert ap1_before['State']['Health']['Status']=='healthy'
assert (art/'ap2-before.txt').read_text().strip()==''
assert ap1['State']['Paused'] is True and ap2['State']['Running'] is True
assert ap2['State']['Health']['Status']=='healthy'
assert ap2['Config']['Labels']['com.docker.compose.project']==state['project']
assert ap2['Config']['Labels']['com.docker.compose.service']=='ap-server-2'
assert before['matched_count']==3
names=[row['event'] for row in events]
required=['MONITOR_READY','AP1_PAUSED_DETECTED','AP2_START_REQUESTED','AP2_STARTED','AP2_ACTIVE']
assert [name for name in names if name in required]==required
assert all(row['monitor_pid']==state['monitor_pid'] for row in events)
times=[datetime.datetime.fromisoformat(next(row['timestamp'] for row in events if row['event']==name)) for name in required]
assert times==sorted(times)
assert state['detected_at']==times[1].isoformat() and state['active_at']==times[4].isoformat()
assert continuity['unchanged'] is True and cleanup['verified'] is True
