#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

[ -s /etc/killercoda/host ] || { echo 'PHASE7-RETRY FAIL reason=killercoda_marker_missing' >&2; exit 1; }
run_id="$(date -u +%Y%m%dT%H%M%S)-$$-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
env_id="$(hostname)-$(cat /proc/sys/kernel/random/boot_id)"
artifact="artifacts/phase7-retry/$env_id/$run_id"
project="phase7retry-$(printf %s "$run_id" | tr -cd 'a-zA-Z0-9' | tr '[:upper:]' '[:lower:]')"
file="$ROOT/tests/test-16.compose.yml"
mkdir -p "$artifact"
kind= started=0 db_paused=0 DB= AP=

compose() {
  if [ "$kind" = plugin ]; then docker compose "$@"; else docker-compose "$@"; fi
}
cleanup() {
  local rc=0
  if [ "$db_paused" = 1 ] && [ -n "$DB" ]; then
    docker unpause "$DB" >>"$artifact/cleanup.log" 2>&1 || rc=1
  fi
  if [ "$started" = 1 ]; then
    compose -p "$project" -f "$file" down -v --remove-orphans >>"$artifact/cleanup.log" 2>&1 || rc=1
  fi
  return "$rc"
}
finish() {
  local rc=$? reason=${reason:-unexpected_exit}
  trap - EXIT INT TERM
  cleanup || { rc=1; reason=cleanup_failed; }
  if [ "$rc" = 0 ]; then
    echo "PHASE7-RETRY PASS environment=$env_id run=$run_id connect_timeout=5 backoff=1,2,4 ap_restart=false db_restart=false business_committed=true artifact=$artifact"
  else
    echo "PHASE7-RETRY FAIL reason=$reason artifact=$artifact" >&2
  fi
  exit "$rc"
}
trap finish EXIT
trap 'reason=signal_INT; exit 130' INT
trap 'reason=signal_TERM; exit 143' TERM

docker version >"$artifact/docker-version.txt" 2>&1 || { reason=docker_unavailable; exit 1; }
if docker compose version >"$artifact/compose-version.txt" 2>&1; then kind=plugin
elif docker-compose version >"$artifact/compose-version.txt" 2>&1; then kind=standalone
else reason=compose_unavailable; exit 1
fi
compose -p "$project" -f "$file" config >"$artifact/compose-config.yml" || { reason=compose_config_failed; exit 1; }
started=1
compose -p "$project" -f "$file" up -d --build db-server ap-server-2 >"$artifact/up.log" 2>&1 || { reason=stack_start_failed; exit 1; }
DB=$(compose -p "$project" -f "$file" ps -q db-server)
AP=$(compose -p "$project" -f "$file" ps -q ap-server-2)
[ -n "$DB" ] && [ -n "$AP" ] || { reason=container_identity_missing; exit 1; }
for _ in $(seq 1 90); do
  db_health=$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null || true)
  ap_health=$(docker inspect -f '{{.State.Health.Status}}' "$AP" 2>/dev/null || true)
  [ "$db_health" = healthy ] && [ "$ap_health" = healthy ] && break
  sleep 1
done
[ "$db_health" = healthy ] && [ "$ap_health" = healthy ] || { reason=readiness_timeout; exit 1; }

pm_before=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()')
db_id_before=$(docker inspect -f '{{.Id}}' "$DB")
ap_id_before=$(docker inspect -f '{{.Id}}' "$AP")
db_restart_before=$(docker inspect -f '{{.RestartCount}}' "$DB")
ap_restart_before=$(docker inspect -f '{{.RestartCount}}' "$AP")
request_id="phase7-retry-$run_id"
printf '%s\n' "$request_id" >"$artifact/request-id.txt"

docker pause "$DB" >/dev/null || { reason=db_pause_failed; exit 1; }
db_paused=1
docker exec -i "$AP" python3 - "$request_id" <<'PY' >"$artifact/batch.json" || { reason=batch_start_failed; exit 1; }
import json,sys,urllib.request
request=urllib.request.Request('http://127.0.0.1:8080/batch',data=json.dumps({'request_ids':[sys.argv[1]]}).encode(),headers={'Content-Type':'application/json'},method='POST')
print(urllib.request.urlopen(request,timeout=5).read().decode())
PY

three_failures=0
for _ in $(seq 1 160); do
  docker logs "$AP" >"$artifact/ap.log" 2>&1 || { reason=ap_log_failed; exit 1; }
  if python3 - "$artifact/ap.log" "$request_id" <<'PY'
import json,sys
rows=[]
for line in open(sys.argv[1],encoding='utf-8'):
 try: row=json.loads(line)
 except json.JSONDecodeError: continue
 if row.get('request_id')==sys.argv[2]: rows.append(row)
backoffs=[r.get('backoff_seconds') for r in rows if r.get('event')=='RETRY_SCHEDULED']
raise SystemExit(0 if backoffs[:3]==[1,2,4] else 1)
PY
  then three_failures=1; break; fi
  sleep .25
done
[ "$three_failures" = 1 ] || { reason=backoff_sequence_not_observed; exit 1; }

docker unpause "$DB" >/dev/null || { reason=db_unpause_failed; exit 1; }
db_paused=0
recovered=0
for _ in $(seq 1 120); do
  docker logs "$AP" >"$artifact/ap.log" 2>&1 || { reason=ap_log_failed; exit 1; }
  if python3 - "$artifact/ap.log" "$request_id" <<'PY'
import json,sys
for line in open(sys.argv[1],encoding='utf-8'):
 try: row=json.loads(line)
 except json.JSONDecodeError: continue
 if row.get('request_id')==sys.argv[2] and row.get('event')=='DB_CONNECTED' and row.get('recovered') is True:
  raise SystemExit(0)
raise SystemExit(1)
PY
  then recovered=1; break; fi
  sleep .25
done
[ "$recovered" = 1 ] || { reason=automatic_recovery_timeout; exit 1; }
docker logs "$AP" >"$artifact/ap.log" 2>&1 || { reason=ap_log_failed; exit 1; }

docker exec -i "$AP" python3 - <<'PY' >"$artifact/ap-state.json" || { reason=state_read_failed; exit 1; }
import urllib.request
print(urllib.request.urlopen('http://127.0.0.1:8080/state',timeout=5).read().decode())
PY
docker exec "$DB" psql -U lab -d lab -At -F '|' -c "SELECT request_id,ap_name FROM business_results WHERE request_id='$request_id'" >"$artifact/business-row.txt" || { reason=business_query_failed; exit 1; }
pm_after=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()')
db_id_after=$(docker inspect -f '{{.Id}}' "$DB")
ap_id_after=$(docker inspect -f '{{.Id}}' "$AP")
db_restart_after=$(docker inspect -f '{{.RestartCount}}' "$DB")
ap_restart_after=$(docker inspect -f '{{.RestartCount}}' "$AP")
python3 - "$artifact/continuity.json" "$pm_before" "$pm_after" "$db_id_before" "$db_id_after" "$ap_id_before" "$ap_id_after" "$db_restart_before" "$db_restart_after" "$ap_restart_before" "$ap_restart_after" <<'PY' || { reason=continuity_write_failed; exit 1; }
import json,sys
keys=('postmaster_before','postmaster_after','db_id_before','db_id_after','ap_id_before','ap_id_after','db_restart_before','db_restart_after','ap_restart_before','ap_restart_after')
value=dict(zip(keys,sys.argv[2:])); value.update({key:int(value[key]) for key in keys if 'restart' in key})
json.dump(value,open(sys.argv[1],'w'),indent=2)
PY
python3 scripts/phase7-retry-validate.py "$artifact" || { reason=evidence_validation_failed; exit 1; }
reason=verified
exit 0
