import json
import pathlib
import sys

art = pathlib.Path(sys.argv[1])
summary = json.loads((art / 'recovery.json').read_text(encoding='utf-8'))
continuity = json.loads((art / 'db-continuity.json').read_text(encoding='utf-8'))
assert summary['business_committed'] is True and summary['after_old'] == 0
assert continuity['postmaster_before'] and continuity['postmaster_before'] == continuity['postmaster_after']
assert continuity['restart_before'] == continuity['restart_after']
assert continuity['container_before'] == continuity['container_after']
assert summary['db_unchanged'] is True
