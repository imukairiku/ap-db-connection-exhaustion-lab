"""Isolated Killercoda capacity probe for TEST-14 (20) and TEST-15 (30)."""

import fcntl
import json
import os
import pathlib
import re
import secrets
import subprocess
import sys
import time
import traceback


ROOT = pathlib.Path(__file__).resolve().parents[1]
os.chdir(ROOT)
NUMBER = sys.argv[1] if len(sys.argv) == 2 else ''
if NUMBER not in ('14', '15'):
    raise SystemExit('usage: phase6-compare.py 14|15')
TEST_ID = f'TEST-{NUMBER}'
EXPECTED_MAX = 20 if NUMBER == '14' else 30
ENV_ID = f'{subprocess.check_output(["hostname"], text=True).strip()}-{pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip()}'
RUN_ID = f'{time.strftime("%Y%m%dT%H%M%S", time.gmtime())}-{os.getpid()}-{secrets.token_hex(4)}'
ART = ROOT / 'artifacts' / f'test-{NUMBER}' / ENV_ID / RUN_ID
ART.mkdir(parents=True, exist_ok=True)
COUNTER = ROOT / 'artifacts' / f'test-{NUMBER}' / 'failure-state.json'
LOCK = ROOT / 'artifacts' / f'test-{NUMBER}' / '.lock'
PROJECT = f'test{NUMBER}-{RUN_ID.lower()}'
TAG = f't{NUMBER}_{re.sub("[^A-Za-z0-9]", "", RUN_ID)[-20:]}'
COMPOSE_FILES = ['-f', str(ROOT / 'tests' / 'test-06.compose.yml')]
if NUMBER == '15':
    COMPOSE_FILES += ['-f', str(ROOT / 'tests' / 'test-15.override.yml')]
COMPOSE = None
DB = AP1 = AP2 = ADMIN = DB_IP = ''
started = paused = out_rule = in_rule = False


def write_json(name, value):
    (ART / name).write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def command(args, name=None, input_text=None, timeout=300):
    result = subprocess.run(args, input=input_text, text=True, capture_output=True, timeout=timeout)
    if name:
        (ART / name).write_text(result.stdout + result.stderr, encoding='utf-8')
    if result.returncode:
        raise RuntimeError(f'{args[0]} {args[1:4]} rc={result.returncode} evidence={name}')
    return result.stdout.strip()


def compose(*args, name=None):
    return command(COMPOSE + ['-p', PROJECT] + COMPOSE_FILES + list(args), name=name)


def inspect(container, template):
    return command(['docker', 'inspect', '-f', template, container])


def db_query(sql, name=None):
    return command(['docker', 'exec', DB, 'psql', '-U', 'lab', '-d', 'lab', '-At', '-F', '|', '-c', sql], name=name)


def wait_for(predicate, label, limit=60, interval=.25):
    for _ in range(int(limit / interval)):
        if predicate():
            return
        time.sleep(interval)
    raise RuntimeError(f'{label} timeout')


BATCH = '''import json,sys,urllib.request
ids=[f'{sys.argv[1]}-{n:02d}' for n in range(1,int(sys.argv[2])+1)]
q=urllib.request.Request('http://127.0.0.1:8080/batch',data=json.dumps({'request_ids':ids}).encode(),headers={'Content-Type':'application/json'},method='POST')
print(urllib.request.urlopen(q,timeout=5).read().decode())
'''


def batch(container, prefix, count, name):
    body = command(['docker', 'exec', '-i', container, 'python3', '-', prefix, str(count)],
                   name=name, input_text=BATCH)
    if len(json.loads(body)['request_ids']) != count:
        raise RuntimeError(f'{name} did not accept {count} requests')


def old_snapshot(label):
    pg = db_query("SELECT pid,client_addr,client_port,backend_start,state FROM pg_stat_activity "
                  "WHERE application_name='ap-server-1' ORDER BY pid", f'{label}-pg.txt')
    ss = command(['docker', 'exec', DB, 'ss', '-Hnt', 'state', 'established', '( sport = :5432 )'],
                 f'{label}-ss.txt')
    command(['python3', 'scripts/test04-snapshot.py', str(ART / f'{label}-pg.txt'),
             str(ART / f'{label}-ss.txt'), str(ART / f'{label}.json')])
    return json.loads((ART / f'{label}.json').read_text(encoding='utf-8'))


def cleanup():
    errors = []
    if started:
        actions = []
        if paused and AP1:
            actions.append(['docker', 'unpause', AP1])
        if out_rule and ADMIN:
            actions.append(['docker', 'exec', ADMIN, 'iptables', '-D', 'OUTPUT', '-p', 'tcp', '-d', DB_IP,
                            '--dport', '5432', '-m', 'comment', '--comment', TAG, '-j', 'DROP'])
        if in_rule and ADMIN:
            actions.append(['docker', 'exec', ADMIN, 'iptables', '-D', 'INPUT', '-p', 'tcp', '-s', DB_IP,
                            '--sport', '5432', '-m', 'comment', '--comment', TAG, '-j', 'DROP'])
        for args in actions:
            try:
                command(args, 'cleanup-actions.log')
            except Exception as error:
                errors.append(str(error))
        if ADMIN:
            try:
                rules = command(['docker', 'exec', ADMIN, 'iptables-save'], 'iptables-cleanup.txt')
                if TAG in rules:
                    errors.append('DROP rule remains')
            except Exception as error:
                errors.append(str(error))
        try:
            compose('down', '--volumes', '--remove-orphans', name='down.log')
        except Exception as error:
            errors.append(str(error))
    for label, args in (
        ('containers', ['docker', 'ps', '-aq', '--filter', f'label=com.docker.compose.project={PROJECT}']),
        ('networks', ['docker', 'network', 'ls', '-q', '--filter', f'label=com.docker.compose.project={PROJECT}']),
        ('volumes', ['docker', 'volume', 'ls', '-q', '--filter', f'label=com.docker.compose.project={PROJECT}']),
    ):
        try:
            count = len(command(args).splitlines())
            if count:
                errors.append(f'{label} remain={count}')
        except Exception as error:
            errors.append(str(error))
    write_json('cleanup.json', {'verified': not errors, 'errors': errors})
    return not errors


def prerequisite_15():
    state_path = ROOT / 'artifacts' / 'test-14' / 'failure-state.json'
    if not state_path.is_file():
        raise SystemExit('TEST-15 BLOCKED: TEST-14 PASS required in this environment')
    history = json.loads(state_path.read_text(encoding='utf-8'))['history']
    if not history or history[-1]['status'] != 'PASS':
        raise SystemExit('TEST-15 BLOCKED: latest TEST-14 result is not PASS')
    old_art = pathlib.Path(history[-1]['artifact_path'])
    if len(old_art.parts) < 4 or old_art.parts[2] != ENV_ID:
        raise SystemExit('TEST-15 BLOCKED: TEST-14 PASS belongs to a different environment')
    return json.loads((old_art / 'capacity.json').read_text(encoding='utf-8'))


def measure():
    global COMPOSE, DB, AP1, AP2, ADMIN, DB_IP, started, paused, out_rule, in_rule
    if not pathlib.Path('/etc/killercoda/host').is_file():
        raise RuntimeError('killercoda marker missing')
    command(['docker', 'version'], 'docker-version.txt')
    plugin = subprocess.run(['docker', 'compose', 'version'], capture_output=True, text=True)
    if plugin.returncode == 0:
        COMPOSE = ['docker', 'compose']
    else:
        standalone = subprocess.run(['docker-compose', 'version'], capture_output=True, text=True)
        if standalone.returncode:
            raise RuntimeError('Compose unavailable')
        COMPOSE = ['docker-compose']
    command(['python3', 'scripts/test01-phase0-inventory.py', 'capture',
             'config/test01-phase0-prerequisite.json', str(ART / 'phase0-prerequisite.json')])
    compose('config', name='compose-config.yml')
    started = True
    compose('up', '-d', '--build', 'db-server', 'ap-server-1', 'ap-netadmin-1', 'management-connections',
            name='up-primary.log')
    DB, AP1, ADMIN = (compose('ps', '-q', service) for service in ('db-server', 'ap-server-1', 'ap-netadmin-1'))
    if not all((DB, AP1, ADMIN)):
        raise RuntimeError('primary container identity missing')
    def primary_ready():
        try:
            healthy = inspect(DB, '{{.State.Health.Status}}') == inspect(AP1, '{{.State.Health.Status}}') == 'healthy'
            compose('logs', 'management-connections', name='management.log')
            mg = 'MANAGEMENT_CONNECTIONS_READY=2' in (ART / 'management.log').read_text(encoding='utf-8')
            return healthy and mg
        except RuntimeError:
            return False
    wait_for(primary_ready, 'primary readiness')
    pm_before = db_query('SELECT pg_postmaster_start_time()')
    restart_before = int(inspect(DB, '{{.RestartCount}}'))
    db_id_before = inspect(DB, '{{.Id}}')
    batch(AP1, f'test{NUMBER}-old-{RUN_ID}', 10, 'ap1-batch.json')
    wait_for(lambda: old_snapshot('old-ready')['matched_count'] == 10, 'old connections')
    DB_IP = inspect(DB, '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    command(['docker', 'exec', ADMIN, 'iptables', '-I', 'OUTPUT', '1', '-p', 'tcp', '-d', DB_IP,
             '--dport', '5432', '-m', 'comment', '--comment', TAG, '-j', 'DROP'])
    out_rule = True
    command(['docker', 'exec', ADMIN, 'iptables', '-I', 'INPUT', '1', '-p', 'tcp', '-s', DB_IP,
             '--sport', '5432', '-m', 'comment', '--comment', TAG, '-j', 'DROP'])
    in_rule = True
    rules = command(['docker', 'exec', ADMIN, 'iptables-save'], 'iptables-after.txt')
    if rules.count(TAG) != 2:
        raise RuntimeError('two DROP rules not verified')
    command(['docker', 'pause', AP1])
    paused = True
    if inspect(AP1, '{{.State.Paused}}') != 'true' or old_snapshot('after-pause')['matched_count'] != 10:
        raise RuntimeError('old AP not paused with ten real DB/TCP connections')
    compose('up', '-d', '--build', 'ap-server-2', name='up-secondary.log')
    AP2 = compose('ps', '-q', 'ap-server-2')
    if not AP2:
        raise RuntimeError('AP2 identity missing')
    wait_for(lambda: inspect(AP2, '{{.State.Health.Status}}') == 'healthy', 'AP2 readiness')
    batch(AP2, f'test{NUMBER}-new-{RUN_ID}', 12, 'ap2-batch.json')
    def settled():
        try:
            raw = command(['docker', 'exec', AP2, 'python3', '-c',
                           "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/state',timeout=2).read().decode())"])
            state = json.loads(raw)
            write_json('ap2-state.json', state)
            return state['accepted'] == 12 and state['connected'] + state['failed'] == 12
        except (RuntimeError, ValueError, KeyError):
            return False
    wait_for(settled, 'AP2 connection attempts')
    state = json.loads((ART / 'ap2-state.json').read_text(encoding='utf-8'))
    failures = [row for row in state['requests'] if row['state'] == 'CONNECTION_FAILED']
    if len(failures) != state['failed'] or any(
        row.get('error_phase') != 'connect' or row.get('error_type') != 'OperationalError'
        for row in failures
    ):
        raise RuntimeError('AP2 failures are not actual PostgreSQL connection errors')
    capacity_sql = ("SELECT current_setting('max_connections'),current_setting('superuser_reserved_connections'),"
                    "count(*) FILTER (WHERE backend_type='client backend' AND pid<>pg_backend_pid()),"
                    "count(*) FILTER (WHERE application_name='ap-server-1'),"
                    "count(*) FILTER (WHERE application_name='ap-server-2'),"
                    "count(*) FILTER (WHERE application_name LIKE 'management-%') "
                    "FROM pg_stat_activity")
    for _ in range(40):
        cap_raw = db_query(capacity_sql, 'capacity.raw')
        with (ART / 'capacity-samples.tsv').open('a', encoding='utf-8') as stream:
            stream.write(f'{time.time():.3f}\t{cap_raw}\n')
        max_conn, reserved, total, old, new, mg = map(int, cap_raw.split('|'))
        if old == 10 and mg == 2 and new == state['connected'] and total == old + new + mg:
            break
        time.sleep(.25)
    else:
        raise RuntimeError('settled DB capacity snapshot did not match AP/management connections')
    command(['docker', 'logs', DB], 'db.log')
    db_log = (ART / 'db.log').read_text(encoding='utf-8')
    fatal_count = len(re.findall(r'FATAL:.*(?:remaining connection slots|too many clients)', db_log, re.I))
    pm_after = db_query('SELECT pg_postmaster_start_time()')
    restart_after = int(inspect(DB, '{{.RestartCount}}'))
    db_id_after = inspect(compose('ps', '-q', 'db-server'), '{{.Id}}')
    record = {
        'test_id': TEST_ID, 'environment_id': ENV_ID, 'run_id': RUN_ID, 'method': 'A',
        'max_connections': max_conn, 'superuser_reserved_connections': reserved,
        'old_ap': old, 'new_ap': new, 'management': mg,
        'requested_new_connections': state['accepted'],
        'successful_new_connections': state['connected'], 'failed_new_connections': state['failed'],
        'final_connections': total, 'other_connections': total - old - new - mg,
        'available_connection_headroom': max_conn - reserved - total,
        'db_fatal_count': fatal_count, 'ap1_paused': inspect(AP1, '{{.State.Paused}}') == 'true',
        'ap2_healthy': inspect(AP2, '{{.State.Health.Status}}') == 'healthy',
        'postmaster_before': pm_before, 'postmaster_after': pm_after,
        'restart_before': restart_before, 'restart_after': restart_after,
        'db_container_before': db_id_before, 'db_container_after': db_id_after,
    }
    write_json('capacity.json', record)
    if max_conn != EXPECTED_MAX or reserved != 3 or old != 10 or mg != 2:
        raise RuntimeError('fixed workload or server capacity mismatch')
    if not (1 <= new <= 12 and new == state['connected'] and old + new + mg == total):
        raise RuntimeError('DB/AP connection counts disagree')
    if state['connected'] + state['failed'] != 12 or record['other_connections'] != 0:
        raise RuntimeError('request outcome or DB backend count mismatch')
    if not (record['ap1_paused'] and record['ap2_healthy']):
        raise RuntimeError('AP state mismatch')
    if pm_before != pm_after or restart_before != restart_after or db_id_before != db_id_after:
        raise RuntimeError('DB restarted or recreated during measurement')
    if NUMBER == '14':
        if state['failed'] < 1 or fatal_count < 1:
            raise RuntimeError('PostgreSQL capacity rejection not observed at max_connections=20')
    else:
        baseline = prerequisite_15()
        if not (baseline['max_connections'] == 20 and baseline['old_ap'] == old and
                baseline['management'] == mg and baseline['requested_new_connections'] == state['accepted']):
            raise RuntimeError('TEST-14/15 workload conditions differ')
        write_json('comparison.json', {
            'test14': {key: baseline[key] for key in ('max_connections', 'old_ap', 'new_ap', 'management',
                       'successful_new_connections', 'failed_new_connections', 'final_connections',
                       'available_connection_headroom')},
            'test15': {key: record[key] for key in ('max_connections', 'old_ap', 'new_ap', 'management',
                       'successful_new_connections', 'failed_new_connections', 'final_connections',
                       'available_connection_headroom')},
            'interpretation': 'Capacity headroom is distinct from Keepalive-based residual-session cleanup.',
        })


def main():
    if NUMBER == '15':
        prerequisite_15()
    with LOCK.open('a+') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit(f'{TEST_ID} BLOCKED: another run is active')
        gate = subprocess.run(['python3', 'scripts/phase5-counter.py', TEST_ID, str(COUNTER), 'gate'],
                              capture_output=True, text=True)
        if gate.returncode:
            raise SystemExit(gate.stderr.strip() or f'{TEST_ID} blocked by failure counter')
        failure = None
        try:
            measure()
        except Exception as error:
            failure = str(error)
            (ART / 'error-traceback.txt').write_text(traceback.format_exc(), encoding='utf-8')
        clean = cleanup()
        if not clean:
            failure = 'cleanup_failed' if failure is None else failure + '; cleanup_failed'
        status = 'PASS' if failure is None else 'FAIL'
        count = int(command(['python3', 'scripts/phase5-counter.py', TEST_ID, str(COUNTER),
                             'finish', RUN_ID, str(ART.relative_to(ROOT)), status, failure or 'verified']))
        if status == 'FAIL':
            print(f'{TEST_ID} FAIL reason={failure} failures={count} artifact={ART.relative_to(ROOT)}', file=sys.stderr)
            raise SystemExit(1)
        record = json.loads((ART / 'capacity.json').read_text(encoding='utf-8'))
        print(f'{TEST_ID} PASS environment={ENV_ID} run={RUN_ID} max_connections={record["max_connections"]} '
              f'old_ap={record["old_ap"]} new_ap={record["new_ap"]} management={record["management"]} '
              f'successful_new_connections={record["successful_new_connections"]} '
              f'failed_new_connections={record["failed_new_connections"]} '
              f'final_connections={record["final_connections"]} '
              f'headroom={record["available_connection_headroom"]} '
              f'postmaster_unchanged=true failures={count} artifact={ART.relative_to(ROOT)}')


if __name__ == '__main__':
    main()
