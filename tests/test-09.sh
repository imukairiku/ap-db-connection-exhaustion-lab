#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$ROOT"
COUNTER=artifacts/test-09/failure-state.json; LOCK=artifacts/test-09/.lock; mkdir -p artifacts/test-09
command -v flock >/dev/null || { echo 'TEST-09 FAIL: flock unavailable' >&2; exit 2; }
exec 9>"$LOCK"; flock -n 9 || { echo 'TEST-09 blocked: another run is active' >&2; exit 3; }
python3 scripts/test09-counter.py "$COUNTER" gate >/dev/null || exit 3
host=$(hostname); boot=$(cat /proc/sys/kernel/random/boot_id); env_id="$host-$boot"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
art="artifacts/test-09/$env_id/$run_id"; mkdir -p "$art"
project="test09-$(printf %s "$run_id" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
tag="t09_$(printf %s "$run_id" | tr -cd 'a-zA-Z0-9' | tail -c 20)"
file="$ROOT/tests/test-06.compose.yml"
kind=; started=0; out_rule=0; in_rule=0; paused=0; finished=0; reason=unexpected_exit; monitor_pid=
DB=; AP1=; ADMIN=; DB_IP=
compose(){ if [ "$kind" = plugin ]; then docker compose "$@"; else docker-compose "$@"; fi; }
cleanup(){
  local rc=0 c n v
  if [ -n "$monitor_pid" ]; then
    if kill -0 "$monitor_pid" 2>/dev/null; then kill "$monitor_pid" 2>/dev/null || rc=1; fi
    wait "$monitor_pid" 2>/dev/null || true
  fi
  if [ "$started" = 1 ]; then
    if [ "$paused" = 1 ]; then docker unpause "$AP1" >>"$art/cleanup.log" 2>&1 || rc=1; fi
    if [ "$out_rule" = 1 ]; then docker exec "$ADMIN" iptables -D OUTPUT -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$tag" -j DROP >>"$art/cleanup.log" 2>&1 || rc=1; fi
    if [ "$in_rule" = 1 ]; then docker exec "$ADMIN" iptables -D INPUT -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$tag" -j DROP >>"$art/cleanup.log" 2>&1 || rc=1; fi
    if [ -n "$ADMIN" ]; then
      if ! docker exec "$ADMIN" iptables-save >"$art/iptables-cleanup.txt"; then rc=1
      elif grep -Fq "$tag" "$art/iptables-cleanup.txt"; then rc=1; fi
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
  [ "$finished" = 0 ] || exit "$rc"
  cleanup || { rc=1; reason=cleanup_failed; }
  if [ "$rc" = 0 ]; then python3 scripts/test09-validate.py "$art" || { rc=1; reason=validation_failed; }; fi
  [ "$rc" = 0 ] && status=PASS
  count=$(python3 scripts/test09-counter.py "$COUNTER" finish "$run_id" "$art" "$status" "$reason") || exit 70
  finished=1
  if [ "$status" = PASS ]; then
    echo "TEST-09 PASS environment=$env_id run=$run_id old_ap=3 new_ap=3 management=2 active=ap-server-2 postmaster_unchanged=true failures=$count artifact=$art"
  else echo "TEST-09 FAIL reason=$reason failures=$count artifact=$art" >&2; fi
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
compose -p "$project" -f "$file" up -d --build db-server ap-server-1 ap-netadmin-1 management-connections >"$art/up-primary.log" 2>&1 || { reason=primary_start_failed; exit 1; }
DB=$(compose -p "$project" -f "$file" ps -q db-server); AP1=$(compose -p "$project" -f "$file" ps -q ap-server-1); ADMIN=$(compose -p "$project" -f "$file" ps -q ap-netadmin-1)
[ -n "$DB" ] && [ -n "$AP1" ] && [ -n "$ADMIN" ] || { reason=identity_failed; exit 1; }
for _ in $(seq 1 60); do
  dh=$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null || true)
  ah=$(docker inspect -f '{{.State.Health.Status}}' "$AP1" 2>/dev/null || true)
  [ "$dh" = healthy ] && [ "$ah" = healthy ] && break
  sleep 1
done
[ "$dh" = healthy ] && [ "$ah" = healthy ] || { reason=readiness_timeout; exit 1; }
PM=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); RESTART=$(docker inspect -f '{{.RestartCount}}' "$DB")
python3 scripts/test08-monitor.py "$project" "$file" "$kind" "$AP1" "$run_id" "$art/failover-state.json" "$art/monitor-events.jsonl" >"$art/monitor.stdout" 2>"$art/monitor.stderr" & monitor_pid=$!
for _ in $(seq 1 40); do
  [ -f "$art/failover-state.json" ] && grep -q '"status": "PRIMARY_ACTIVE"' "$art/failover-state.json" && break
  kill -0 "$monitor_pid" 2>/dev/null || break
  sleep .25
done
[ -f "$art/failover-state.json" ] && grep -q '"status": "PRIMARY_ACTIVE"' "$art/failover-state.json" || { reason=monitor_not_ready; exit 1; }
batch(){
  docker exec -i "$1" python3 - "$2" <<'PY'
import json,sys,urllib.request
ids=[f'{sys.argv[1]}-{n:02d}' for n in range(1,4)]
request=urllib.request.Request('http://127.0.0.1:8080/batch',data=json.dumps({'request_ids':ids}).encode(),headers={'Content-Type':'application/json'},method='POST')
print(urllib.request.urlopen(request,timeout=5).read().decode())
PY
}
snapshot(){
  docker exec "$DB" psql -U lab -d lab -At -F '|' -c "SELECT application_name,pid,client_addr,client_port,backend_start,state_change,state FROM pg_stat_activity WHERE application_name IN ('ap-server-1','ap-server-2','management-1','management-2') ORDER BY pid" >"$1"
}
batch "$AP1" "test09-old-$run_id" >"$art/ap1-batch.json" || { reason=old_batch_failed; exit 1; }
for _ in $(seq 1 60); do
  snapshot "$art/before.raw" || { reason=before_snapshot_failed; exit 1; }
  [ "$(grep -c '^ap-server-1|' "$art/before.raw")" = 3 ] && [ "$(grep -c '^management-' "$art/before.raw")" = 2 ] && break
  sleep .25
done
[ "$(grep -c '^ap-server-1|' "$art/before.raw")" = 3 ] && [ "$(grep -c '^management-' "$art/before.raw")" = 2 ] || { reason=old_or_management_not_ready; exit 1; }
DB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DB")
docker exec "$ADMIN" iptables -I OUTPUT 1 -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$tag" -j DROP || { reason=output_drop_failed; exit 1; }; out_rule=1
docker exec "$ADMIN" iptables -I INPUT 1 -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$tag" -j DROP || { reason=input_drop_failed; exit 1; }; in_rule=1
docker exec "$ADMIN" iptables-save >"$art/iptables-after.txt"
[ "$(grep -c -- "$tag" "$art/iptables-after.txt")" = 2 ] || { reason=drop_verification_failed; exit 1; }
docker pause "$AP1" >/dev/null || { reason=pause_failed; exit 1; }; paused=1
for _ in $(seq 1 120); do
  [ -f "$art/failover-state.json" ] && grep -q '"status": "ACTIVE"' "$art/failover-state.json" && break
  kill -0 "$monitor_pid" 2>/dev/null || break
  sleep .5
done
wait "$monitor_pid" || { monitor_pid=; reason=monitor_failed; exit 1; }; monitor_pid=
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["active_service"])' "$art/failover-state.json")" = ap-server-2 ] || { reason=failover_not_active; exit 1; }
AP2=$(compose -p "$project" -f "$file" ps -q ap-server-2); [ -n "$AP2" ] || { reason=ap2_missing; exit 1; }
batch "$AP2" "test09-new-$run_id" >"$art/ap2-batch.json" || { reason=new_batch_failed; exit 1; }
for _ in $(seq 1 60); do
  snapshot "$art/after.raw" || { reason=after_snapshot_failed; exit 1; }
  [ "$(grep -c '^ap-server-2|' "$art/after.raw")" = 3 ] && break
  sleep .25
done
AP1_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$AP1")
AP2_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$AP2")
PM2=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); RESTART2=$(docker inspect -f '{{.RestartCount}}' "$DB")
AP1_PAUSED=$(docker inspect -f '{{.State.Paused}}' "$AP1"); AP2_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$AP2")
[ "$RESTART" = "$RESTART2" ] || { reason=db_restarted; exit 1; }
python3 scripts/test09-identify.py "$art/before.raw" "$art/after.raw" "$art/identification.json" "$AP1_IP" "$AP2_IP" "$PM" "$PM2" "$AP1_PAUSED" "$AP2_HEALTH" || { reason=identification_failed; exit 1; }
reason=verified
exit 0
