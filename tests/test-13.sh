#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$ROOT"
COUNTER=artifacts/test-13/failure-state.json; LOCK=artifacts/test-13/.lock; mkdir -p artifacts/test-13
command -v flock >/dev/null || { echo 'TEST-13 FAIL: flock unavailable' >&2; exit 2; }
exec 9>"$LOCK"; flock -n 9 || { echo 'TEST-13 blocked: another run is active' >&2; exit 3; }
env_id="$(hostname)-$(cat /proc/sys/kernel/random/boot_id)"
python3 - "$env_id" <<'PY' || { echo 'TEST-13 BLOCKED: TEST-12 must PASS in this Killercoda session first' >&2; exit 3; }
import json,pathlib,sys
p=pathlib.Path('artifacts/test-12/failure-state.json')
assert p.is_file()
h=json.loads(p.read_text(encoding='utf-8'))['history']
assert h and h[-1]['status']=='PASS' and pathlib.Path(h[-1]['artifact_path']).parts[2]==sys.argv[1]
PY
python3 scripts/phase5-counter.py TEST-13 "$COUNTER" gate >/dev/null || exit 3
run_id="$(date -u +%Y%m%dT%H%M%S)-$$-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
art="artifacts/test-13/$env_id/$run_id"; mkdir -p "$art"
project="test13-$(printf %s "$run_id" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
tag="t13_$(printf %s "$run_id" | tr -cd 'a-zA-Z0-9' | tail -c 20)"
file="$ROOT/tests/test-13.compose.yml"; export PHASE5_REQUEST_ID="test13-recovered-$run_id"
kind=; started=0; out_rule=0; in_rule=0; reason=unexpected_exit; DB=; AP=; ADMIN=; DB_IP=
compose(){ if [ "$kind" = plugin ]; then docker compose "$@"; else docker-compose "$@"; fi; }
cleanup(){
  local rc=0 c n v
  if [ "$started" = 1 ]; then
    if [ "$out_rule" = 1 ]; then docker exec "$ADMIN" iptables -D OUTPUT -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$tag" -j DROP >>"$art/cleanup.log" 2>&1 || rc=1; fi
    if [ "$in_rule" = 1 ]; then docker exec "$ADMIN" iptables -D INPUT -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$tag" -j DROP >>"$art/cleanup.log" 2>&1 || rc=1; fi
    if [ -n "$ADMIN" ]; then
      docker exec "$ADMIN" iptables-save >"$art/iptables-cleanup.txt" || rc=1
      grep -Fq "$tag" "$art/iptables-cleanup.txt" && rc=1
    fi
    compose -p "$project" -f "$file" down --volumes --remove-orphans >>"$art/cleanup.log" 2>&1 || rc=1
  fi
  c=$(docker ps -aq --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')
  n=$(docker network ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')
  v=$(docker volume ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')
  python3 - "$art/cleanup.json" "$c" "$n" "$v" <<'PY' || rc=1
import json,sys
c,n,v=map(int,sys.argv[2:]); json.dump({'containers':c,'networks':n,'volumes':v,'verified':c==n==v==0},open(sys.argv[1],'w'),indent=2)
raise SystemExit(0 if c==n==v==0 else 1)
PY
  return "$rc"
}
finalize(){
  local rc=$? status=FAIL count
  trap - EXIT INT TERM
  cleanup || { rc=1; reason=cleanup_failed; }
  if [ "$rc" = 0 ]; then python3 scripts/test13-validate.py "$art" || { rc=1; reason=validation_failed; }; fi
  [ "$rc" = 0 ] && status=PASS
  count=$(python3 scripts/phase5-counter.py TEST-13 "$COUNTER" finish "$run_id" "$art" "$status" "$reason") || exit 70
  if [ "$status" = PASS ]; then
    echo "TEST-13 PASS environment=$env_id run=$run_id connect_timeout=5 backoff=1,2,4 failures_before_recovery=3 ap_restart=false db_restart=false business_committed=true failures=$count artifact=$art"
  else echo "TEST-13 FAIL reason=$reason failures=$count artifact=$art" >&2; fi
  exit "$rc"
}
trap finalize EXIT; trap 'reason=signal_INT; exit 130' INT; trap 'reason=signal_TERM; exit 143' TERM
[ -s /etc/killercoda/host ] || { reason=killercoda_marker_missing; exit 1; }
docker version >"$art/docker-version.txt" 2>&1 || { reason=docker_unavailable; exit 1; }
if docker compose version >"$art/compose-version.txt" 2>&1; then kind=plugin
elif docker-compose version >"$art/compose-version.txt" 2>&1; then kind=standalone
else reason=compose_unavailable; exit 1; fi
python3 scripts/test01-phase0-inventory.py capture config/test01-phase0-prerequisite.json "$art/phase0-prerequisite.json" || { reason=phase0_prerequisite_invalid; exit 1; }
compose -p "$project" -f "$file" config >"$art/compose-config.yml" || { reason=compose_config_failed; exit 1; }
started=1
compose -p "$project" -f "$file" up -d --build >"$art/up.log" 2>&1 || { reason=stack_start_failed; exit 1; }
DB=$(compose -p "$project" -f "$file" ps -q db-server); AP=$(compose -p "$project" -f "$file" ps -q ap-server-2); ADMIN=$(compose -p "$project" -f "$file" ps -q ap-netadmin-2)
[ -n "$DB" ] && [ -n "$AP" ] && [ -n "$ADMIN" ] || { reason=identity_failed; exit 1; }
for _ in $(seq 1 60); do
  dh=$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null || true)
  docker logs "$AP" >"$art/ap.log" 2>&1
  [ "$dh" = healthy ] && grep -q '"event": "READY"' "$art/ap.log" && break
  sleep 1
done
[ "$dh" = healthy ] && grep -q '"event": "READY"' "$art/ap.log" || { reason=readiness_timeout; exit 1; }
PM=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); DB_RESTART=$(docker inspect -f '{{.RestartCount}}' "$DB"); AP_RESTART=$(docker inspect -f '{{.RestartCount}}' "$AP")
DB_ID=$(docker inspect -f '{{.Id}}' "$DB"); AP_ID=$(docker inspect -f '{{.Id}}' "$AP")
DB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DB")
docker exec "$ADMIN" iptables -I OUTPUT 1 -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$tag" -j DROP || { reason=output_drop_failed; exit 1; }; out_rule=1
docker exec "$ADMIN" iptables -I INPUT 1 -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$tag" -j DROP || { reason=input_drop_failed; exit 1; }; in_rule=1
docker exec "$ADMIN" iptables-save >"$art/iptables-after.txt"
[ "$(grep -c -- "$tag" "$art/iptables-after.txt")" = 2 ] || { reason=drop_verification_failed; exit 1; }
docker exec "$AP" touch /tmp/start-retry || { reason=retry_start_failed; exit 1; }
three_failed=0
for _ in $(seq 1 120); do
  docker logs "$AP" >"$art/ap.log" 2>&1
  python3 - "$art/ap.log" <<'PY' && { three_failed=1; break; }
import json,sys
rows=[json.loads(x) for x in open(sys.argv[1]) if x.startswith('{')]
assert any(x.get('event')=='BACKOFF_START' and x.get('attempt')==3 and x.get('seconds')==4 for x in rows)
PY
  sleep .25
done
[ "$three_failed" = 1 ] || { reason=three_failures_not_observed; exit 1; }
docker exec "$ADMIN" iptables -D OUTPUT -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$tag" -j DROP || { reason=output_restore_failed; exit 1; }; out_rule=0
docker exec "$ADMIN" iptables -D INPUT -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$tag" -j DROP || { reason=input_restore_failed; exit 1; }; in_rule=0
recovered=0
for _ in $(seq 1 80); do
  docker logs "$AP" >"$art/ap.log" 2>&1
  grep -q '"event": "BUSINESS_COMMITTED"' "$art/ap.log" && { recovered=1; break; }
  sleep .25
done
[ "$recovered" = 1 ] || { reason=auto_reconnect_timeout; exit 1; }
docker exec "$DB" psql -U lab -d lab -At -F '|' -c "SELECT request_id,ap_name FROM business_results WHERE request_id='$PHASE5_REQUEST_ID'" >"$art/business-row.txt" || { reason=business_query_failed; exit 1; }
PM2=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); DB_RESTART2=$(docker inspect -f '{{.RestartCount}}' "$DB"); AP_RESTART2=$(docker inspect -f '{{.RestartCount}}' "$AP")
DB_ID2=$(docker inspect -f '{{.Id}}' "$(compose -p "$project" -f "$file" ps -q db-server)"); AP_ID2=$(docker inspect -f '{{.Id}}' "$(compose -p "$project" -f "$file" ps -q ap-server-2)")
python3 - "$art/continuity.json" "$PM" "$PM2" "$DB_RESTART" "$DB_RESTART2" "$AP_RESTART" "$AP_RESTART2" "$DB_ID" "$DB_ID2" "$AP_ID" "$AP_ID2" <<'PY' || { reason=continuity_write_failed; exit 1; }
import json,sys
path,pm,pm2,dr,dr2,ar,ar2,db,db2,ap,ap2=sys.argv[1:]
json.dump({'postmaster_before':pm,'postmaster_after':pm2,'db_restart_before':int(dr),'db_restart_after':int(dr2),'ap_restart_before':int(ar),'ap_restart_after':int(ar2),'db_id_before':db,'db_id_after':db2,'ap_id_before':ap,'ap_id_after':ap2},open(path,'w'),indent=2)
PY
reason=verified
exit 0
