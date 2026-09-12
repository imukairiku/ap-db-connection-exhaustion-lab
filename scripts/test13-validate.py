import json
import pathlib
import sys

art = pathlib.Path(sys.argv[1])
rows = [json.loads(line) for line in (art / 'ap.log').read_text(encoding='utf-8').splitlines() if line.startswith('{')]
by_event = lambda event: [r for r in rows if r.get('event') == event]
ready = by_event('READY')
attempts = by_event('CONNECT_ATTEMPT')
failed = by_event('CONNECT_FAILED')
backs = by_event('BACKOFF_START')
ends = by_event('BACKOFF_END')
connected = by_event('DB_CONNECTED')
committed = by_event('BUSINESS_COMMITTED')
assert len(ready) == 1 and ready[0]['connect_timeout'] == 5
assert len(failed) == len(backs) == len(ends) == 3
assert [r['attempt'] for r in failed] == [1, 2, 3]
assert [r['seconds'] for r in backs] == [1, 2, 4]
assert len(attempts) == 4 and [r['attempt'] for r in attempts] == [1, 2, 3, 4]
assert len(connected) == len(committed) == 1 and connected[0]['attempt'] == committed[0]['attempt'] == 4
assert all(r['error_type'] == 'OperationalError' and 4.0 <= r['elapsed_seconds'] <= 7.0 for r in failed)
for index, delay in enumerate((1, 2, 4)):
    assert 0.8 * delay <= ends[index]['elapsed_seconds'] <= delay + .8
    assert attempts[index]['monotonic'] < failed[index]['monotonic'] < backs[index]['monotonic']
    assert backs[index]['monotonic'] < ends[index]['monotonic'] <= attempts[index + 1]['monotonic']
assert attempts[3]['monotonic'] < connected[0]['monotonic'] < committed[0]['monotonic']
request_id = ready[0]['request_id']
assert (art / 'business-row.txt').read_text(encoding='utf-8').strip() == f'{request_id}|ap-server-2'
continuity = json.loads((art / 'continuity.json').read_text(encoding='utf-8'))
assert continuity['postmaster_before'] and continuity['postmaster_before'] == continuity['postmaster_after']
assert continuity['db_restart_before'] == continuity['db_restart_after']
assert continuity['ap_restart_before'] == continuity['ap_restart_after']
assert continuity['db_id_before'] == continuity['db_id_after']
assert continuity['ap_id_before'] == continuity['ap_id_after']
assert json.loads((art / 'cleanup.json').read_text(encoding='utf-8'))['verified'] is True
