#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$ROOT"
COUNTER=artifacts/test-11/failure-state.json; LOCK=artifacts/test-11/.lock; mkdir -p artifacts/test-11
command -v flock >/dev/null || { echo 'TEST-11 FAIL: flock unavailable' >&2; exit 2; }
exec 9>"$LOCK"; flock -n 9 || { echo 'TEST-11 blocked: another run is active' >&2; exit 3; }
python3 scripts/phase4-counter.py TEST-11 "$COUNTER" gate >/dev/null || exit 3
host=$(hostname); boot=$(cat /proc/sys/kernel/random/boot_id); env_id="$host-$boot"
pointer=artifacts/phase4/test10-current.json
# A missing or stale TEST-10 PASS is a prerequisite block, not a TEST-11 failure.
python3 - "$pointer" "$env_id" <<'PY' || { echo 'TEST-11 BLOCKED: run TEST-10 successfully first; TEST-11 was not evaluated' >&2; exit 3; }
import json,pathlib,sys
path=pathlib.Path(sys.argv[1]); env=sys.argv[2]
assert path.is_file()
p=json.loads(path.read_text(encoding='utf-8'))
history=json.loads(pathlib.Path('artifacts/test-10/failure-state.json').read_text(encoding='utf-8'))['history']
assert p['status']=='PASS' and p['test_id']=='TEST-10' and p['environment_id']==env
assert history and history[-1]['status']=='PASS' and history[-1]['run_id']==p['run_id']
assert history[-1]['artifact_path']==p['artifact_path']
assert pathlib.Path(p['artifact_path']).is_dir()
PY
read -r run_id art < <(python3 - "$pointer" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); print(p['run_id'],p['artifact_path'])
PY
)
reason=validation_failed
if python3 scripts/test10-validate.py "$art" && python3 scripts/test11-validate.py "$art"; then
  reason=verified; status=PASS; rc=0
else status=FAIL; rc=1; fi
count=$(python3 scripts/phase4-counter.py TEST-11 "$COUNTER" finish "$run_id" "$art" "$status" "$reason") || exit 70
if [ "$status" = PASS ]; then
  echo "TEST-11 PASS environment=$env_id run=$run_id postmaster_unchanged=true db_container_unchanged=true restart_count_unchanged=true ap2_business_committed=true failures=$count artifact=$art"
else echo "TEST-11 FAIL reason=$reason failures=$count artifact=$art" >&2; fi
exit "$rc"
