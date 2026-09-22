#!/usr/bin/env python3
"""Isolated Phase 7 scenario lifecycle and state-based verification."""
import json
import pathlib
import shlex
import subprocess
import sys
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
ART = ROOT / 'artifacts' / 'phase7'
STATE = ART / 'current.json'
COMPOSE_FILE = ROOT / 'tests' / 'test-16.compose.yml'


def run(args, *, input=None, check=True):
    proc = subprocess.run(args, input=input, text=True, capture_output=True, cwd=ROOT)
    if check and proc.returncode:
        raise RuntimeError(f'{args!r}: rc={proc.returncode} stdout={proc.stdout[-1000:]} stderr={proc.stderr[-1000:]}')
    return proc


def compose_base():
    if run(['docker', 'compose', 'version'], check=False).returncode == 0:
        command = ['docker', 'compose']
        kind = 'plugin'
    elif run(['docker-compose', 'version'], check=False).returncode == 0:
        command = ['docker-compose']
        kind = 'standalone'
    else:
        raise RuntimeError('Docker Compose unavailable')
    boot = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip().split('-')[0]
    return command + ['-p', f'phase7-{boot}', '-f', str(COMPOSE_FILE)], kind


def load():
    return json.loads(STATE.read_text(encoding='utf-8'))


def save(value):
    ART.mkdir(parents=True, exist_ok=True)
    temporary = STATE.with_name(STATE.name + '.tmp-' + uuid.uuid4().hex)
    temporary.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
    temporary.replace(STATE)


def cid(compose, service):
    value = run(compose + ['ps', '-q', service]).stdout.strip()
    if not value:
        raise RuntimeError(f'{service} container missing')
    return value


def inspect(container, template):
    return run(['docker', 'inspect', '-f', template, container]).stdout.strip()


def psql(db, query):
    return run(['docker', 'exec', db, 'psql', '-U', 'lab', '-d', 'lab', '-At', '-F', '|', '-c', query]).stdout.strip()


def rows(db):
    query = "SELECT application_name,pid,client_addr,client_port,backend_start,state_change,state FROM pg_stat_activity WHERE application_name IN ('ap-server-1','ap-server-2','management-1','management-2') ORDER BY pid"
    output = psql(db, query)
    values = []
    for line in output.splitlines():
        app, pid, addr, port, started, changed, state = line.split('|')
        values.append({'application_name': app, 'pid': int(pid), 'client_addr': addr,
                       'client_port': int(port), 'backend_start': started,
                       'state_change': changed, 'state': state})
    return values


def wait_for(predicate, message, attempts=100, interval=.25):
    for _ in range(attempts):
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    raise RuntimeError(message)


def ap_http(container, path, ids=None):
    code = '''import json,sys,urllib.request
url='http://127.0.0.1:8080/'+sys.argv[1]
data=json.dumps({'request_ids':json.loads(sys.argv[2])}).encode() if len(sys.argv)>2 else None
request=urllib.request.Request(url,data=data,headers={'Content-Type':'application/json'})
print(urllib.request.urlopen(request,timeout=5).read().decode())'''
    args = ['docker', 'exec', '-i', container, 'python3', '-c', code, path]
    if ids is not None:
        args.append(json.dumps(ids))
    return json.loads(run(args).stdout)


def health(container):
    return inspect(container, '{{.State.Running}}/{{.State.Health.Status}}') == 'true/healthy'


def remove_own_rules(admin):
    listing = run(['docker', 'exec', admin, 'iptables', '-S'], check=False)
    if listing.returncode:
        raise RuntimeError('cannot inspect fault rules')
    for line in listing.stdout.splitlines():
        if 'phase7_' not in line or not line.startswith('-A '):
            continue
        parts = shlex.split(line)
        run(['docker', 'exec', admin, 'iptables', '-D'] + parts[1:])
    after = run(['docker', 'exec', admin, 'iptables-save']).stdout
    if 'phase7_' in after:
        raise RuntimeError('Phase 7 DROP rule still present')


def reset():
    compose, kind = compose_base()
    existing = run(compose + ['ps', '-q', 'ap-server-1'], check=False).stdout.strip()
    if existing:
        admin = run(compose + ['ps', '-q', 'ap-netadmin-1'], check=False).stdout.strip()
        if inspect(existing, '{{.State.Paused}}') == 'true':
            run(['docker', 'unpause', existing])
        if admin:
            remove_own_rules(admin)
    run(compose + ['down', '-v', '--remove-orphans'])
    if run(['docker', 'ps', '-aq', '--filter', f'label=com.docker.compose.project={compose[compose.index("-p") + 1]}']).stdout.strip():
        raise RuntimeError('old project containers remain')
    run(compose + ['up', '-d', '--build', 'db-server', 'ap-server-1', 'ap-netadmin-1', 'management-connections'])
    db, ap1, admin = (cid(compose, service) for service in ('db-server', 'ap-server-1', 'ap-netadmin-1'))
    wait_for(lambda: health(db) and health(ap1), 'DB/AP1 readiness timeout', 120, 1)
    wait_for(lambda: len([r for r in rows(db) if r['application_name'].startswith('management-')]) == 2,
             'management sessions missing', 120, .5)
    if run(compose + ['ps', '-q', 'ap-server-2']).stdout.strip():
        raise RuntimeError('AP2 started before fault')
    if inspect(ap1, '{{.State.Paused}}') != 'false':
        raise RuntimeError('AP1 remains paused')
    remove_own_rules(admin)
    run_id = uuid.uuid4().hex[:12]
    value = {'schema_version': 1, 'project': compose[compose.index('-p') + 1],
             'compose_kind': kind, 'run_id': run_id, 'stage': 'HEALTHY',
             'db_container_id': inspect(db, '{{.Id}}'), 'ap1_container_id': ap1,
             'postmaster_start': psql(db, 'SELECT pg_postmaster_start_time()'),
             'restart_count': int(inspect(db, '{{.RestartCount}}'))}
    save(value)
    business('ap-server-1')
    return load()


def business(service='ap-server-2'):
    compose, _ = compose_base()
    container = cid(compose, service)
    db = cid(compose, 'db-server')
    request_id = 'phase7-business-' + uuid.uuid4().hex
    code = '''import os,psycopg2,sys
with psycopg2.connect(host=os.environ['DB_HOST'],user='app_user',password='app-only',dbname='lab',application_name=os.environ['AP_NAME'],connect_timeout=5) as conn:
 with conn.cursor() as cur: cur.execute('INSERT INTO business_results(request_id,ap_name) VALUES(%s,%s)',(sys.argv[1],os.environ['AP_NAME']))
print(sys.argv[1])'''
    run(['docker', 'exec', '-i', container, 'python3', '-c', code, request_id])
    result = psql(db, "SELECT ap_name FROM business_results WHERE request_id='" + request_id + "'")
    if result != service:
        raise RuntimeError('business COMMIT not visible in DB')
    value = load()
    value['last_business'] = {'request_id': request_id, 'service': service}
    save(value)
    return request_id


def inject():
    value = load()
    if value['stage'] != 'HEALTHY':
        raise RuntimeError('reset to HEALTHY before injecting')
    compose, kind = compose_base()
    db, ap1, admin = (cid(compose, service) for service in ('db-server', 'ap-server-1', 'ap-netadmin-1'))
    if inspect(db, '{{.Id}}') != value['db_container_id']:
        raise RuntimeError('DB container changed since baseline')
    state_path = ART / 'failover-state.json'
    events_path = ART / 'monitor-events.jsonl'
    state_path.unlink(missing_ok=True)
    events_path.unlink(missing_ok=True)
    monitor = subprocess.Popen([sys.executable, str(ROOT / 'scripts' / 'test08-monitor.py'),
                                value['project'], str(COMPOSE_FILE), kind, ap1,
                                value['run_id'], str(state_path), str(events_path)],
                               stdout=(ART / 'monitor.stdout').open('w'),
                               stderr=(ART / 'monitor.stderr').open('w'), cwd=ROOT)
    try:
        wait_for(lambda: state_path.exists() and json.loads(state_path.read_text())['status'] == 'PRIMARY_ACTIVE',
                 'monitor not ready', 80, .25)
        prefix = 'phase7-old-' + value['run_id']
        ap_http(ap1, 'batch', [f'{prefix}-{n:02d}' for n in range(1, 11)])
        old = wait_for(lambda: [r for r in rows(db) if r['application_name'] == 'ap-server-1']
                       if len([r for r in rows(db) if r['application_name'] == 'ap-server-1']) == 10 else None,
                       'ten AP1 sessions not established', 80, .25)
        pg = '\n'.join('|'.join(str(r[key]) for key in ('pid','client_addr','client_port','backend_start','state')) for r in old) + '\n'
        (ART / 'old-pg.txt').write_text(pg, encoding='utf-8')
        ss = run(['docker', 'exec', db, 'ss', '-Hnt', 'state', 'established', '( sport = :5432 )']).stdout
        (ART / 'old-ss.txt').write_text(ss, encoding='utf-8')
        snapshot = ROOT / 'scripts' / 'test04-snapshot.py'
        run(['python3', str(snapshot), str(ART / 'old-pg.txt'), str(ART / 'old-ss.txt'), str(ART / 'old-snapshot.json')])
        if json.loads((ART / 'old-snapshot.json').read_text())['matched_count'] != 10:
            raise RuntimeError('AP1 TCP/PG sessions do not match')
        ip = inspect(db, '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
        tag = 'phase7_' + value['run_id']
        run(['docker', 'exec', admin, 'iptables', '-I', 'OUTPUT', '1', '-p', 'tcp', '-d', ip,
             '--dport', '5432', '-m', 'comment', '--comment', tag, '-j', 'DROP'])
        run(['docker', 'exec', admin, 'iptables', '-I', 'INPUT', '1', '-p', 'tcp', '-s', ip,
             '--sport', '5432', '-m', 'comment', '--comment', tag, '-j', 'DROP'])
        if run(['docker', 'exec', admin, 'iptables-save']).stdout.count(tag) != 2:
            raise RuntimeError('DROP rules not verified')
        run(['docker', 'pause', ap1])
        if monitor.wait(timeout=90):
            raise RuntimeError('automatic failover monitor failed')
        failover = json.loads(state_path.read_text())
        if failover['status'] != 'ACTIVE' or failover['active_service'] != 'ap-server-2':
            raise RuntimeError('AP2 did not become ACTIVE')
        ap2 = cid(compose, 'ap-server-2')
        ap_http(ap2, 'batch', [f'phase7-new-{value["run_id"]}-{n:02d}' for n in range(1, 13)])
        ap2_state = wait_for(lambda: (s if s['accepted'] == 12 and s['connected'] >= 1 and
                                      s['connection_failures'] >= 1 else None)
                             if (s := ap_http(ap2, 'state')) else None,
                             'AP2 connection failures not observed', 120, .25)
        current_rows = rows(db)
        old_after = [r for r in current_rows if r['application_name'] == 'ap-server-1']
        if len(old_after) != 10 or inspect(ap1, '{{.State.Paused}}') != 'true':
            raise RuntimeError('old AP sessions or pause lost')
        (ART / 'old-after-pg.txt').write_text(
            '\n'.join('|'.join(str(r[key]) for key in ('pid', 'client_addr', 'client_port', 'backend_start', 'state'))
                      for r in old_after) + '\n', encoding='utf-8')
        (ART / 'old-after-ss.txt').write_text(
            run(['docker', 'exec', db, 'ss', '-Hnt', 'state', 'established', '( sport = :5432 )']).stdout,
            encoding='utf-8')
        run(['python3', str(snapshot), str(ART / 'old-after-pg.txt'),
             str(ART / 'old-after-ss.txt'), str(ART / 'old-after-snapshot.json')])
        after_match = json.loads((ART / 'old-after-snapshot.json').read_text())['matched_count']
        if after_match != 10:
            raise RuntimeError('AP1 residual TCP/PG sessions do not match')
        if psql(db, 'SELECT pg_postmaster_start_time()') != value['postmaster_start']:
            raise RuntimeError('postmaster changed during fault')
        db_log = run(['docker', 'logs', db])
        (ART / 'db.log').write_text(db_log.stdout + db_log.stderr, encoding='utf-8')
        ap2_log = run(['docker', 'logs', ap2])
        (ART / 'ap2.log').write_text(ap2_log.stdout + ap2_log.stderr, encoding='utf-8')
        if not any(x in db_log.stdout + db_log.stderr for x in ('too many clients', 'remaining connection slots')):
            raise RuntimeError('real DB capacity FATAL not observed')
        value.update(stage='INCIDENT', ap2_container_id=ap2, tag=tag, db_ip=ip,
                     old_sessions=old, preserved_sessions=[r for r in current_rows if r['application_name'] == 'ap-server-2' or r['application_name'].startswith('management-')],
                     ap2_failed=ap2_state['connection_failures'], ap2_connected=ap2_state['connected'],
                     residual_pg_ss_matched=after_match,
                     failover_state=str(state_path.relative_to(ROOT)))
        save(value)
        return value
    finally:
        if monitor.poll() is None:
            monitor.terminate()
            monitor.wait(timeout=5)


def verify(mode):
    value = load()
    compose, _ = compose_base()
    reasons = []
    db = cid(compose, 'db-server')
    current = rows(db)
    if inspect(db, '{{.Id}}') != value['db_container_id']:
        reasons.append('db_container_changed')
    if psql(db, 'SELECT pg_postmaster_start_time()') != value['postmaster_start']:
        reasons.append('postmaster_changed')
    if int(inspect(db, '{{.RestartCount}}')) != value['restart_count']:
        reasons.append('restart_count_changed')
    if value['stage'] != 'INCIDENT':
        reasons.append('incident_not_recorded')
    ap1 = cid(compose, 'ap-server-1')
    if inspect(ap1, '{{.State.Paused}}') != 'true':
        reasons.append('ap1_not_paused')
    ap2 = cid(compose, 'ap-server-2')
    if not health(ap2):
        reasons.append('ap2_unhealthy')
    if not pathlib.Path(ROOT / value['failover_state']).exists():
        reasons.append('failover_state_missing')
    else:
        failover = json.loads((ROOT / value['failover_state']).read_text())
        if failover.get('active_service') != 'ap-server-2' or failover.get('status') != 'ACTIVE' or failover.get('ap2_container_id') != ap2:
            reasons.append('automatic_failover_not_active')
    old = [r for r in current if r['application_name'] == 'ap-server-1']
    new = [r for r in current if r['application_name'] == 'ap-server-2']
    management = [r for r in current if r['application_name'].startswith('management-')]
    if mode == 'incident':
        if len(old) < 3:
            reasons.append('old_sessions_missing')
        if value.get('residual_pg_ss_matched', 0) < 3:
            reasons.append('old_tcp_pg_match_missing')
        if value.get('ap2_failed', 0) < 1:
            reasons.append('ap2_failure_missing')
    elif mode == 'recovery':
        if old:
            reasons.append('old_sessions_remain')
        originals = {(r['application_name'], r['pid'], r['backend_start']) for r in value.get('preserved_sessions', [])}
        still = {(r['application_name'], r['pid'], r['backend_start']) for r in current}
        if not originals or not originals.issubset(still):
            reasons.append('healthy_sessions_disrupted')
        business_value = value.get('last_business', {})
        request_id = business_value.get('request_id', '')
        if business_value.get('service') != 'ap-server-2' or not request_id.startswith('phase7-business-'):
            reasons.append('ap2_business_not_recorded')
        elif psql(db, "SELECT ap_name FROM business_results WHERE request_id='" + request_id + "'") != 'ap-server-2':
            reasons.append('ap2_business_not_committed')
    else:
        raise ValueError(mode)
    report = {'mode': mode, 'pass': not reasons, 'reasons': reasons,
              'old_ap': len(old), 'new_ap': len(new), 'management': len(management),
              'postmaster': psql(db, 'SELECT pg_postmaster_start_time()'),
              'db_container_id': inspect(db, '{{.Id}}'),
              'restart_count': int(inspect(db, '{{.RestartCount}}'))}
    return report


def main():
    command = sys.argv[1]
    if command == 'reset':
        result = reset()
    elif command == 'inject':
        result = inject()
    elif command == 'business':
        result = {'request_id': business(sys.argv[2] if len(sys.argv) > 2 else 'ap-server-2')}
    elif command == 'verify':
        result = verify(sys.argv[2])
    elif command == 'state':
        result = load()
    else:
        raise SystemExit('usage: phase7-lab.py reset|inject|business [service]|verify incident|recovery|state')
    print(json.dumps(result, indent=2))
    if command == 'verify' and not result['pass']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
