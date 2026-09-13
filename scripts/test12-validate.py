import json
import pathlib
import sys

art = pathlib.Path(sys.argv[1])
before = json.loads((art / 'before.json').read_text())
immediate = json.loads((art / 'immediate.json').read_text())
current = json.loads((art / 'current.json').read_text())
measure = json.loads((art / 'measurement.json').read_text())
cleanup = json.loads((art / 'cleanup.json').read_text())
unix_diagnostic = (art / 'unix-socket-settings.txt').read_text(encoding='utf-8').strip()
assert unix_diagnostic.startswith('unix|'), unix_diagnostic
for name in ('db-tcp-settings.txt', 'ap-to-db-tcp-settings.txt'):
    observed = (art / name).read_text(encoding='utf-8').strip()
    assert observed == 'tcp|20|5|3', (name, observed)
kernel_defaults = [int(x) for x in (art / 'kernel-keepalive-defaults.txt').read_text().splitlines()]
assert len(kernel_defaults) == 3 and all(x > 0 for x in kernel_defaults)
sources = [line.split('|') for line in (art / 'db-tcp-setting-sources.txt').read_text().splitlines()]
assert {row[0]: (row[1], row[2]) for row in sources} == {
    'tcp_keepalives_count': ('3', 'command line'),
    'tcp_keepalives_idle': ('20', 'command line'),
    'tcp_keepalives_interval': ('5', 'command line'),
}
assert before['matched_count'] == immediate['matched_count'] == 3
assert {r['pid'] for r in before['pg_rows']} == {r['pid'] for r in immediate['pg_rows']}
assert current['pg_count'] == current['ss_count'] == 0
assert 0 < measure['elapsed_seconds'] <= 100
assert measure['postmaster_before'] == measure['postmaster_after']
assert measure['restart_before'] == measure['restart_after']
assert cleanup['verified'] is True
