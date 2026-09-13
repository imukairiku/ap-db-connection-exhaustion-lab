"""Exit 0 when retry attempt 3 enters backoff, 1 while pending, 2 on bad evidence."""

import json
import pathlib
import sys

try:
    lines = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
    events = [json.loads(line) for line in lines if line.startswith('{')]
except (IndexError, OSError, UnicodeError, json.JSONDecodeError) as error:
    print(f'TEST-13 polling evidence error: {error}', file=sys.stderr)
    raise SystemExit(2)

if any(event.get('event') == 'BACKOFF_START' and event.get('attempt') == 3
       and event.get('seconds') == 4 for event in events):
    raise SystemExit(0)
raise SystemExit(1)
