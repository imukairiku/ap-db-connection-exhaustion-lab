#!/usr/bin/env python3
"""Killercoda-only TEST-16..18 harness. Tests are strictly gated in order."""
import importlib.util
import json
import pathlib
import subprocess
import sys
import time
import traceback
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('phase7_lab', ROOT / 'scripts' / 'phase7-lab.py')
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)
environment = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
environment = f'{subprocess.run(["hostname"], capture_output=True, text=True, check=True).stdout.strip()}-{environment}'
number = int(sys.argv[1])
if number not in (16, 17, 18):
    raise SystemExit('TEST-ID must be 16, 17 or 18')
run_id = time.strftime('%Y%m%dT%H%M%S', time.gmtime()) + '-' + uuid.uuid4().hex[:8]
art = ROOT / 'artifacts' / f'test-{number:02d}' / environment / run_id
art.mkdir(parents=True, exist_ok=True)
gate_path = ROOT / 'artifacts' / 'phase7' / 'test-gate.json'
counter_path = ROOT / 'artifacts' / 'phase7' / 'failure-counts.json'
if number == 16:
    gate_path.unlink(missing_ok=True)


def record(name, value):
    (art / name).write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def gate(expected):
    if not gate_path.exists():
        raise RuntimeError(f'TEST-{expected:02d} PASS prerequisite missing')
    value = json.loads(gate_path.read_text())
    if value.get('environment') != environment or value.get('latest_pass') != expected:
        raise RuntimeError(f'TEST-{expected:02d} PASS prerequisite invalid')


def test16():
    # Start with a genuine fault, reset it, validate healthy behavior, then fault again.
    lab.reset()
    initial = lab.inject()
    record('initial-incident.json', lab.verify('incident'))
    if not lab.verify('incident')['pass']:
        raise RuntimeError('initial incident not real')
    old_ap = initial['ap1_container_id']
    healthy = lab.reset()
    compose, _ = lab.compose_base()
    current_ap = lab.cid(compose, 'ap-server-1')
    admin = lab.cid(compose, 'ap-netadmin-1')
    if old_ap == current_ap:
        raise RuntimeError('reset did not recreate AP1')
    if lab.inspect(current_ap, '{{.State.Paused}}') != 'false':
        raise RuntimeError('reset left AP1 paused')
    if 'phase7_' in lab.run(['docker', 'exec', admin, 'iptables-save']).stdout:
        raise RuntimeError('reset left DROP rules')
    if lab.psql(lab.cid(compose, 'db-server'), "SELECT ap_name FROM business_results WHERE request_id='" + healthy['last_business']['request_id'] + "'") != 'ap-server-1':
        raise RuntimeError('normal AP1 business not COMMITTED')
    incident = lab.inject()
    report = lab.verify('incident')
    record('after-reset-incident.json', report)
    if not report['pass'] or report['old_ap'] < 3 or incident['ap2_failed'] < 1:
        raise RuntimeError('reset did not permit re-injection')
    return {'old_before_reset': len(initial['old_sessions']),
            'normal_business_committed': True, 'old_after_reinject': report['old_ap'],
            'ap2_failed': incident['ap2_failed'], 'drop_rules_after_reset': 0,
            'ap1_paused_after_reset': False}


def test17():
    gate(16)
    incident = lab.verify('incident')
    if not incident['pass']:
        raise RuntimeError('TEST-16 incident no longer valid')
    value = lab.load()
    compose, _ = lab.compose_base()
    db = lab.cid(compose, 'db-server')
    ap1 = lab.cid(compose, 'ap-server-1')
    raw = art / 'before.raw'
    raw.write_text('\n'.join('|'.join(str(r[key]) for key in
                    ('application_name', 'pid', 'client_addr', 'client_port', 'backend_start', 'state_change', 'state'))
                    for r in lab.rows(db)) + '\n', encoding='utf-8')
    ap1_ip = lab.inspect(ap1, '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    result = lab.run(['python3', str(ROOT / 'scripts' / 'test10-terminate.py'), db,
                      str(raw), ap1_ip, str(art / 'targeted-termination.json')])
    record('termination-command.json', {'stdout': result.stdout, 'stderr': result.stderr})
    lab.wait_for(lambda: len([r for r in lab.rows(db) if r['application_name'] == 'ap-server-1']) == 0,
                 'old AP sessions remain', 80, .25)
    request_id = lab.business('ap-server-2')
    report = lab.verify('recovery')
    record('recovery-verify.json', report)
    if not report['pass']:
        raise RuntimeError('correct recovery rejected: ' + ','.join(report['reasons']))
    return {'old_before': incident['old_ap'], 'old_after': report['old_ap'],
            'new_preserved': True, 'management_preserved': True,
            'ap2_business_request_id': request_id, 'postmaster_unchanged': True}


def test18():
    gate(17)
    lab.reset()
    lab.inject()
    if not lab.verify('incident')['pass']:
        raise RuntimeError('negative-test incident not real')
    compose, _ = lab.compose_base()
    db = lab.cid(compose, 'db-server')
    before = lab.load()
    # Intentional wrong action, confined to this negative test's isolated project.
    lab.run(['docker', 'restart', db])
    lab.wait_for(lambda: lab.health(db), 'DB did not become healthy after wrong restart', 120, 1)
    request_id = lab.business('ap-server-2')
    report = lab.verify('recovery')
    record('wrong-recovery-verify.json', report)
    restart_evidence = {'db_container_changed', 'postmaster_changed', 'restart_count_changed'}
    if report['pass'] or not restart_evidence.intersection(report['reasons']):
        raise RuntimeError('verify failed to reject DB restart for continuity')
    if report['postmaster'] == before['postmaster_start']:
        raise RuntimeError('postmaster start did not change')
    return {'verify_result': 'FAIL', 'verify_reasons': report['reasons'],
            'business_committed_after_wrong_restart': bool(request_id),
            'postmaster_changed': True}


status = 'FAIL'
details = {}
try:
    if not pathlib.Path('/etc/killercoda/host').is_file():
        raise RuntimeError('Killercoda marker missing')
    details = {16: test16, 17: test17, 18: test18}[number]()
    status = 'PASS'
except Exception as error:
    details = {'reason': str(error), 'traceback': traceback.format_exc()}
finally:
    result = {'test_id': f'TEST-{number:02d}', 'status': status,
              'environment': environment, 'run': run_id, 'details': details}
    counts = json.loads(counter_path.read_text()) if counter_path.exists() else {}
    key = f'TEST-{number:02d}'
    counts[key] = 0 if status == 'PASS' else counts.get(key, 0) + 1
    counter_path.parent.mkdir(parents=True, exist_ok=True)
    counter_path.write_text(json.dumps(counts, indent=2) + '\n', encoding='utf-8')
    result['consecutive_failures'] = counts[key]
    record('result.json', result)
    if status == 'PASS':
        gate_path.parent.mkdir(parents=True, exist_ok=True)
        gate_path.write_text(json.dumps({'environment': environment, 'latest_pass': number,
                                         'run': run_id}) + '\n', encoding='utf-8')
        metrics = ' '.join(f'{key}={value}' for key, value in details.items() if not isinstance(value, list))
        print(f'TEST-{number:02d} PASS environment={environment} run={run_id} {metrics} failures=0 artifact={art.relative_to(ROOT)}')
    else:
        print(f'TEST-{number:02d} FAIL reason={details.get("reason")} failures={counts[key]} artifact={art.relative_to(ROOT)}', file=sys.stderr)
        print(details.get('traceback', ''), file=sys.stderr)
raise SystemExit(0 if status == 'PASS' else 1)
