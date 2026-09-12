import json
import pathlib
import subprocess
import sys

db, before_path, ap1_ip, output_path = sys.argv[1:]
rows = []
for line in pathlib.Path(before_path).read_text(encoding='utf-8').splitlines():
    if line.startswith('ap-server-1|'):
        app, pid, addr, port, started, changed, state = line.split('|')
        assert addr == ap1_ip and pid.isdecimal() and started
        rows.append(dict(pid=int(pid), client_addr=addr, backend_start=started))
assert len(rows) == 10 and len({r['pid'] for r in rows}) == 10

outcomes = []
for row in rows:
    # Recheck all identifying attributes in the same SQL statement as termination.
    started = row['backend_start'].replace("'", "''")
    addr = row['client_addr'].replace("'", "''")
    sql = ("SELECT coalesce((SELECT CASE WHEN pg_terminate_backend(pid) THEN 'terminated' ELSE 'failed' END "
           "FROM pg_stat_activity WHERE pid = {pid} AND application_name = 'ap-server-1' "
           "AND client_addr = '{addr}'::inet AND backend_start = '{started}'::timestamptz), 'missing')"
           ).format(pid=row['pid'], addr=addr, started=started)
    result = subprocess.run(['docker', 'exec', db, 'psql', '-U', 'lab', '-d', 'lab', '-At', '-c', sql],
                            capture_output=True, text=True, check=True)
    status = result.stdout.strip()
    assert status in ('terminated', 'missing'), (row, status, result.stderr)
    outcomes.append(dict(**row, status=status))
pathlib.Path(output_path).write_text(json.dumps(outcomes, indent=2) + '\n', encoding='utf-8')
