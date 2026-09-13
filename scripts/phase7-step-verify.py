#!/usr/bin/env python3
"""Killercoda step gates inspect live containers and PostgreSQL, not commands."""
import importlib.util
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('phase7_lab', ROOT / 'scripts' / 'phase7-lab.py')
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)
step = int(sys.argv[1])
if step not in range(1, 8):
    raise SystemExit('step must be 1..7')
mode = 'incident' if step <= 4 else 'recovery'
result = lab.verify(mode)
reasons = result['reasons']
if step == 3:
    compose, _ = lab.compose_base()
    db = lab.cid(compose, 'db-server')
    if lab.psql(db, 'SHOW max_connections') != '20':
        reasons.append('max_connections_not_20')
    db_log = lab.run(['docker', 'logs', db])
    if not any(text in db_log.stdout + db_log.stderr
               for text in ('too many clients', 'remaining connection slots')):
        reasons.append('real_capacity_failure_missing')
if step == 4 and (result['new_ap'] < 1 or result['management'] != 2):
    reasons.append('connection_classes_not_distinct')
if step == 6:
    compose, _ = lab.compose_base()
    db = lab.cid(compose, 'db-server')
    settings = [lab.psql(db, 'SHOW ' + key) for key in
                ('tcp_keepalives_idle', 'tcp_keepalives_interval', 'tcp_keepalives_count')]
    if settings != ['20', '5', '3']:
        reasons.append('keepalive_settings_not_20_5_3')
if step == 7:
    value = lab.load().get('last_business', {})
    if value.get('service') != 'ap-server-2':
        reasons.append('ap2_retest_missing')
result['step'] = step
result['pass'] = not reasons
print(json.dumps(result, indent=2))
raise SystemExit(0 if result['pass'] else 1)
