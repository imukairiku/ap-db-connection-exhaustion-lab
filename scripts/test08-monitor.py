import datetime
import json
import os
import pathlib
import subprocess
import sys
import time

project, compose_file, kind, ap1, run_id, state_path, events_path = sys.argv[1:]
state_path = pathlib.Path(state_path)
events_path = pathlib.Path(events_path)
base = ['docker', 'compose'] if kind == 'plugin' else ['docker-compose']
compose = base + ['-p', project, '-f', compose_file]


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def event(name, **extra):
    row = {'timestamp': now(), 'event': name, 'run_id': run_id, 'project': project,
           'monitor_pid': os.getpid(), **extra}
    with events_path.open('a', encoding='utf-8') as stream:
        stream.write(json.dumps(row) + '\n')
        stream.flush()
        os.fsync(stream.fileno())
    return row['timestamp']


def write_state(status, active_service, **extra):
    value = {'schema_version': 1, 'run_id': run_id, 'project': project,
             'status': status, 'active_service': active_service, 'monitor_pid': os.getpid(), **extra}
    temporary = state_path.with_name(state_path.name + f'.tmp-{os.getpid()}')
    with temporary.open('w', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, state_path)


write_state('PRIMARY_ACTIVE', 'ap-server-1', ap1_container_id=ap1)
event('MONITOR_READY', ap1_container_id=ap1)
for _ in range(240):
    inspected = subprocess.run(['docker', 'inspect', '-f', '{{.State.Paused}}', ap1],
                               capture_output=True, text=True)
    if inspected.returncode == 0 and inspected.stdout.strip() == 'true':
        detected_at = event('AP1_PAUSED_DETECTED', ap1_container_id=ap1)
        write_state('FAILOVER_IN_PROGRESS', '', ap1_container_id=ap1, detected_at=detected_at)
        event('AP2_START_REQUESTED')
        started = subprocess.run(compose + ['up', '-d', '--build', 'ap-server-2'],
                                 capture_output=True, text=True)
        if started.returncode:
            event('AP2_START_FAILED', rc=started.returncode, stderr=started.stderr[-2000:])
            raise SystemExit(started.returncode)
        ids = subprocess.run(compose + ['ps', '-q', 'ap-server-2'], capture_output=True, text=True)
        ap2 = ids.stdout.strip()
        if ids.returncode or not ap2:
            event('AP2_ID_MISSING')
            raise SystemExit(1)
        event('AP2_STARTED', ap2_container_id=ap2)
        for _ in range(120):
            health = subprocess.run(['docker', 'inspect', '-f', '{{.State.Running}}/{{.State.Health.Status}}', ap2],
                                    capture_output=True, text=True)
            if health.returncode == 0 and health.stdout.strip() == 'true/healthy':
                active_at = event('AP2_ACTIVE', ap2_container_id=ap2)
                write_state('ACTIVE', 'ap-server-2', ap1_container_id=ap1,
                            ap2_container_id=ap2, detected_at=detected_at, active_at=active_at)
                raise SystemExit(0)
            time.sleep(.5)
        event('AP2_HEALTH_TIMEOUT', ap2_container_id=ap2)
        raise SystemExit(1)
    time.sleep(.25)
event('AP1_DETECTION_TIMEOUT')
raise SystemExit(1)
