#!/usr/bin/env python3
"""Validate focused Phase 7 retry evidence without introducing a TEST-ID."""
import json
import pathlib
import sys

artifact = pathlib.Path(sys.argv[1])
events = []
for line in (artifact / 'ap.log').read_text(encoding='utf-8').splitlines():
    try:
        value = json.loads(line)
    except json.JSONDecodeError:
        continue
    if value.get('request_id') == (artifact / 'request-id.txt').read_text().strip():
        events.append(value)

failures = [row for row in events if row.get('event') == 'CONNECTION_FAILED']
backoffs = [row for row in events if row.get('event') == 'RETRY_SCHEDULED']
connected = [row for row in events if row.get('event') == 'DB_CONNECTED']
committed = [row for row in events if row.get('event') == 'BUSINESS_COMMITTED']
assert [row['attempt'] for row in failures[:3]] == [1, 2, 3], failures
assert all(row['connect_timeout'] == 5 for row in failures[:3]), failures
assert [row['backoff_seconds'] for row in backoffs[:3]] == [1, 2, 4], backoffs
assert connected and connected[-1]['attempt'] >= 4 and connected[-1]['recovered'] is True, connected
assert committed and committed[-1]['attempt'] == connected[-1]['attempt'], committed

state = json.loads((artifact / 'ap-state.json').read_text(encoding='utf-8'))
assert state['accepted'] == 1 and state['connected'] == 1, state
assert state['connection_failures'] >= 3 and state['retrying'] == 0, state
request = state['requests'][0]
assert request['backoffs'][:3] == [1, 2, 4] and request['recovered'] is True, request

request_id = (artifact / 'request-id.txt').read_text().strip()
assert (artifact / 'business-row.txt').read_text().strip() == f'{request_id}|ap-server-2'
continuity = json.loads((artifact / 'continuity.json').read_text(encoding='utf-8'))
assert continuity['postmaster_before'] == continuity['postmaster_after'], continuity
assert continuity['db_id_before'] == continuity['db_id_after'], continuity
assert continuity['ap_id_before'] == continuity['ap_id_after'], continuity
assert continuity['db_restart_before'] == continuity['db_restart_after'] == 0, continuity
assert continuity['ap_restart_before'] == continuity['ap_restart_after'] == 0, continuity
