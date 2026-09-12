import json
import pathlib
import sys

art = pathlib.Path(sys.argv[1])
before = json.loads((art / 'before.json').read_text())
immediate = json.loads((art / 'immediate.json').read_text())
current = json.loads((art / 'current.json').read_text())
measure = json.loads((art / 'measurement.json').read_text())
cleanup = json.loads((art / 'cleanup.json').read_text())
settings = [x.strip() for x in (art / 'keepalive-settings.txt').read_text().splitlines()]
assert settings == ['20', '5', '3'], settings
assert before['matched_count'] == immediate['matched_count'] == 3
assert {r['pid'] for r in before['pg_rows']} == {r['pid'] for r in immediate['pg_rows']}
assert current['pg_count'] == current['ss_count'] == 0
assert 0 < measure['elapsed_seconds'] <= 100
assert measure['postmaster_before'] == measure['postmaster_after']
assert measure['restart_before'] == measure['restart_after']
assert cleanup['verified'] is True
