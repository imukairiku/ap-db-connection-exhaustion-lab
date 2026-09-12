import datetime
import json
import os
import sys

path, action = sys.argv[1:3]
state = json.load(open(path, encoding='utf-8')) if os.path.exists(path) else {'schema_version': 1, 'consecutive_failures': 0, 'stopped': False, 'history': []}
if action == 'gate':
    if state['stopped'] or state['consecutive_failures'] >= 3:
        raise SystemExit('TEST-09 blocked after three consecutive failures')
    print(state['consecutive_failures'])
elif action == 'finish':
    run, artifact, status, reason = sys.argv[3:]
    state['consecutive_failures'] = 0 if status == 'PASS' else state['consecutive_failures'] + 1
    state['stopped'] = state['consecutive_failures'] >= 3
    state['history'] = (state['history'] + [dict(timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(), run_id=run, artifact_path=artifact, status=status, reason=reason)])[-3:]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = f'{path}.tmp-{os.getpid()}'
    with open(temporary, 'w', encoding='utf-8') as stream:
        json.dump(state, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    print(state['consecutive_failures'])
else:
    raise SystemExit('action must be gate or finish')
