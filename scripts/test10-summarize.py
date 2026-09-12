import json
import pathlib
import sys

art = pathlib.Path(sys.argv[1])

def rows(name):
    result = []
    for line in (art / name).read_text(encoding='utf-8').splitlines():
        if line:
            app, pid, addr, port, started, changed, state = line.split('|')
            result.append(dict(application_name=app, pid=int(pid), client_addr=addr,
                               backend_start=started, state_change=changed, state=state))
    return result

before, after = rows('before.raw'), rows('after.raw')
def group(data, name):
    return [r for r in data if r['application_name'] == name]
old_before, old_after = group(before, 'ap-server-1'), group(after, 'ap-server-1')
new_before, new_after = group(before, 'ap-server-2'), group(after, 'ap-server-2')
mg_before = [r for r in before if r['application_name'].startswith('management-')]
mg_after = [r for r in after if r['application_name'].startswith('management-')]
identity = lambda data: {(r['pid'], r['backend_start']) for r in data}
business_id = (art / 'business-id.txt').read_text(encoding='utf-8').strip()
verified = (art / 'business-verified.txt').read_text(encoding='utf-8').strip()
continuity = json.loads((art / 'db-continuity.json').read_text(encoding='utf-8'))
ap2_state = json.loads((art / 'ap2-state.json').read_text(encoding='utf-8'))
summary = dict(before_old=len(old_before), after_old=len(old_after), before_new=len(new_before),
               after_new=len(new_after), before_management=len(mg_before), after_management=len(mg_after),
               new_failures=ap2_state['failed'],
               new_pids_preserved=identity(new_before) == identity(new_after),
               management_pids_preserved=identity(mg_before) == identity(mg_after),
               business_committed=bool(business_id) and verified == business_id + '|ap-server-2',
               db_unchanged=continuity['postmaster_before'] == continuity['postmaster_after'] and
                            continuity['restart_before'] == continuity['restart_after'] and
                            continuity['container_before'] == continuity['container_after'],
               business_request_id=business_id)
(art / 'recovery.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
assert summary['before_old'] == 10 and summary['after_old'] == 0
assert 1 <= summary['before_new'] == summary['after_new'] <= 5 and summary['new_failures'] >= 1
assert summary['before_management'] == summary['after_management'] == 2
assert summary['new_pids_preserved'] and summary['management_pids_preserved']
assert summary['business_committed'] and summary['db_unchanged']
