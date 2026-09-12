import json
import pathlib
import sys

before_path, after_path, out_path, ap1_ip, ap2_ip, pm_before, pm_after, ap1_paused, ap2_healthy = sys.argv[1:]

def rows(path):
    result = []
    for line in pathlib.Path(path).read_text(encoding='utf-8').splitlines():
        if not line:
            continue
        fields = line.split('|')
        if len(fields) != 7:
            raise ValueError(f'invalid pg_stat_activity row: {line!r}')
        app, pid, addr, port, started, changed, state = fields
        result.append(dict(application_name=app, pid=int(pid), client_addr=addr,
                           client_port=int(port), backend_start=started,
                           state_change=changed, state=state))
    return result

before, after = rows(before_path), rows(after_path)
old_before = [r for r in before if r['application_name'] == 'ap-server-1']
old_after = [r for r in after if r['application_name'] == 'ap-server-1']
new_after = [r for r in after if r['application_name'] == 'ap-server-2']
management = [r for r in after if r['application_name'] in ('management-1', 'management-2')]
required = ('application_name', 'client_addr', 'backend_start', 'state_change', 'state')
data = dict(before_ap1=len(old_before), after_ap1=len(old_after), after_ap2=len(new_after),
            after_management=len(management), old_pids_preserved={r['pid'] for r in old_before} == {r['pid'] for r in old_after},
            old_backends_preserved={ (r['pid'], r['backend_start']) for r in old_before } ==
                                   { (r['pid'], r['backend_start']) for r in old_after },
            all_addresses_match=all(r['client_addr'] == ap1_ip for r in old_after) and
                                all(r['client_addr'] == ap2_ip for r in new_after) and ap1_ip != ap2_ip,
            all_required_fields_present=all(all(r.get(k) for k in required) for r in old_after + new_after + management),
            postmaster_unchanged=pm_before == pm_after, ap1_paused=ap1_paused == 'true',
            ap2_healthy=ap2_healthy == 'healthy', ap1_ip=ap1_ip, ap2_ip=ap2_ip,
            old_connections=old_after, new_connections=new_after, management_connections=management)
pathlib.Path(out_path).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
assert data['before_ap1'] == data['after_ap1'] == data['after_ap2'] == 3
assert data['after_management'] == 2 and data['old_pids_preserved'] and data['old_backends_preserved']
assert data['all_addresses_match'] and data['all_required_fields_present']
assert data['postmaster_unchanged'] and data['ap1_paused'] and data['ap2_healthy']
