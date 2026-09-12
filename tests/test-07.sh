#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$ROOT"
COUNTER=artifacts/test-07/failure-state.json; LOCK=artifacts/test-07/.lock
mkdir -p artifacts/test-07
command -v flock >/dev/null || { echo 'TEST-07 FAIL: flock unavailable' >&2; exit 2; }
exec 9>"$LOCK"; flock -n 9 || { echo 'TEST-07 blocked: another run is active' >&2; exit 3; }
previous=$(python3 scripts/test07-counter.py "$COUNTER" gate) || exit 3
host=$(hostname); boot=$(cat /proc/sys/kernel/random/boot_id)
env_id="$host-$boot"; run_id="$(date -u +%Y%m%dT%H%M%S)-$$-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
art="artifacts/test-07/$env_id/$run_id"; mkdir -p "$art"
project="test07-$(printf %s "$run_id" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
tag="t07_$(printf %s "$run_id" | tr -cd 'a-zA-Z0-9' | tail -c 20)"
file="$ROOT/tests/test-06.compose.yml"
kind=; started=0; output_rule=0; input_rule=0; paused=0; finished=0; reason=unexpected_exit
DB=; AP1=; AP2=; ADMIN=; DB_IP=
compose(){ if [ "$kind" = plugin ]; then docker compose "$@"; else docker-compose "$@"; fi; }
cleanup(){
  local rc=0 c n v
  if [ "$started" = 1 ]; then
    if [ "$paused" = 1 ]; then docker unpause "$AP1" >>"$art/cleanup.log" 2>&1 || rc=1; fi
    if [ "$output_rule" = 1 ]; then docker exec "$ADMIN" iptables -D OUTPUT -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$tag" -j DROP >>"$art/cleanup.log" 2>&1 || rc=1; fi
    if [ "$input_rule" = 1 ]; then docker exec "$ADMIN" iptables -D INPUT -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$tag" -j DROP >>"$art/cleanup.log" 2>&1 || rc=1; fi
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
  local rc=$? status=FAIL count failed=0 logged=0
  trap - EXIT INT TERM
  [ "$finished" = 0 ] || exit "$rc"
  cleanup || { rc=1; reason=cleanup_failed; }
  if [ "$rc" = 0 ]; then python3 scripts/test07-validate.py "$art" || { rc=1; reason=validation_failed; }; fi
  [ "$rc" = 0 ] && status=PASS
  if [ -f "$art/ap2-state.json" ]; then failed=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["failed"])' "$art/ap2-state.json"); fi
  if [ -f "$art/ap2.log" ]; then logged=$(python3 -c 'import json,sys; print(sum(json.loads(line).get("event")=="CONNECTION_FAILED" for line in open(sys.argv[1]) if line.strip().startswith("{")))' "$art/ap2.log"); fi
  count=$(python3 scripts/test07-counter.py "$COUNTER" finish "$run_id" "$art" "$status" "$reason") || exit 70
  finished=1
  if [ "$status" = PASS ]; then
    echo "TEST-07 PASS environment=$env_id run=$run_id ap2_failed=$failed ap2_logged=$logged db_fatal=true postmaster_unchanged=true failures=$count artifact=$art"
  else echo "TEST-07 FAIL reason=$reason failures=$count artifact=$art" >&2; fi
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
  management=$(compose -p "$project" -f "$file" logs management-connections 2>&1)
  [ "$dh" = healthy ] && [ "$ah" = healthy ] && grep -q 'MANAGEMENT_CONNECTIONS_READY=2' <<<"$management" && break
  sleep 1
done
[ "$dh" = healthy ] && [ "$ah" = healthy ] && grep -q 'MANAGEMENT_CONNECTIONS_READY=2' <<<"$management" || { reason=readiness_timeout; exit 1; }
PM=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); RESTART=$(docker inspect -f '{{.RestartCount}}' "$DB")
prefix="test07-old-$run_id"
docker exec -i "$AP1" python3 - "$prefix" <<'PY' >"$art/ap1-batch.json" || { reason=old_batch_failed; exit 1; }
import json,sys,urllib.request
ids=[f'{sys.argv[1]}-{n:02d}' for n in range(1,11)]
request=urllib.request.Request('http://127.0.0.1:8080/batch',data=json.dumps({'request_ids':ids}).encode(),headers={'Content-Type':'application/json'},method='POST')
print(urllib.request.urlopen(request,timeout=5).read().decode())
PY
old_ready=0
for _ in $(seq 1 60); do
  docker exec "$DB" psql -U lab -d lab -At -F '|' -c "SELECT pid,client_addr,client_port,backend_start,state FROM pg_stat_activity WHERE application_name='ap-server-1' ORDER BY pid" >"$art/old-pg.txt" || { reason=old_pg_failed; exit 1; }
  docker exec "$DB" ss -Hnt state established '( sport = :5432 )' >"$art/old-ss.txt" || { reason=old_ss_failed; exit 1; }
  python3 scripts/test04-snapshot.py "$art/old-pg.txt" "$art/old-ss.txt" "$art/old-connections.json" || { reason=old_snapshot_failed; exit 1; }
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["matched_count"])' "$art/old-connections.json")" = 10 ] && { old_ready=1; break; }
  sleep .25
done
[ "$old_ready" = 1 ] || { reason=old_connections_not_10; exit 1; }
DB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DB")
docker exec "$ADMIN" iptables -I OUTPUT 1 -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$tag" -j DROP || { reason=output_drop_failed; exit 1; }; output_rule=1
docker exec "$ADMIN" iptables -I INPUT 1 -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$tag" -j DROP || { reason=input_drop_failed; exit 1; }; input_rule=1
docker exec "$ADMIN" iptables-save >"$art/iptables-after.txt"
[ "$(grep -c -- "$tag" "$art/iptables-after.txt")" = 2 ] || { reason=drop_verification_failed; exit 1; }
docker pause "$AP1" >/dev/null || { reason=pause_failed; exit 1; }; paused=1
[ "$(docker inspect -f '{{.State.Paused}}' "$AP1")" = true ] || { reason=pause_not_observed; exit 1; }
compose -p "$project" -f "$file" up -d --build ap-server-2 >"$art/up-secondary.log" 2>&1 || { reason=secondary_start_failed; exit 1; }
AP2=$(compose -p "$project" -f "$file" ps -q ap-server-2); [ -n "$AP2" ] || { reason=secondary_identity_failed; exit 1; }
for _ in $(seq 1 60); do
  a2h=$(docker inspect -f '{{.State.Health.Status}}' "$AP2" 2>/dev/null || true)
  [ "$a2h" = healthy ] && break
  sleep 1
done
[ "$a2h" = healthy ] || { reason=secondary_health_timeout; exit 1; }
prefix="test07-new-$run_id"
docker exec -i "$AP2" python3 - "$prefix" <<'PY' >"$art/ap2-batch.json" || { reason=new_batch_failed; exit 1; }
import json,sys,urllib.request
ids=[f'{sys.argv[1]}-{n:02d}' for n in range(1,13)]
request=urllib.request.Request('http://127.0.0.1:8080/batch',data=json.dumps({'request_ids':ids}).encode(),headers={'Content-Type':'application/json'},method='POST')
print(urllib.request.urlopen(request,timeout=5).read().decode())
PY
settled=0
for _ in $(seq 1 60); do
  docker exec -i "$AP2" python3 - <<'PY' >"$art/ap2-state.json"
import urllib.request
print(urllib.request.urlopen('http://127.0.0.1:8080/state',timeout=2).read().decode())
PY
  read -r connected failed < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["connected"],d["failed"])' "$art/ap2-state.json")
  [ "$connected" -ge 1 ] && [ "$failed" -ge 1 ] && [ $((connected+failed)) = 12 ] && { settled=1; break; }
  sleep .25
done
[ "$settled" = 1 ] || { reason=new_requests_not_settled; exit 1; }
docker logs "$AP2" >"$art/ap2.log" 2>&1 || { reason=ap_log_capture_failed; exit 1; }
docker logs "$DB" >"$art/db.log" 2>&1 || { reason=db_log_capture_failed; exit 1; }
docker exec "$DB" psql -U lab -d lab -At -F '|' -c "SELECT current_setting('max_connections'),count(*) FILTER (WHERE backend_type='client backend'),count(*) FILTER (WHERE application_name='ap-server-1'),count(*) FILTER (WHERE application_name='ap-server-2'),count(*) FILTER (WHERE application_name LIKE 'management-%') FROM pg_stat_activity" >"$art/db-capacity.raw" || { reason=capacity_query_failed; exit 1; }
python3 - "$art/db-capacity.raw" "$art/db-capacity.json" <<'PY' || { reason=capacity_parse_failed; exit 1; }
import json,sys
m,total,a1,a2,mg=map(int,open(sys.argv[1]).read().strip().split('|'))
json.dump({'max_connections':m,'numbackends':total,'ap_server_1':a1,'ap_server_2':a2,'management':mg},open(sys.argv[2],'w'),indent=2)
PY
PM2=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); RESTART2=$(docker inspect -f '{{.RestartCount}}' "$DB")
python3 - "$art/db-continuity.json" "$PM" "$PM2" "$RESTART" "$RESTART2" <<'PY'
import json,sys
json.dump({'postmaster_before':sys.argv[2],'postmaster_after':sys.argv[3],'restart_before':int(sys.argv[4]),'restart_after':int(sys.argv[5]),'unchanged':sys.argv[2]==sys.argv[3] and sys.argv[4]==sys.argv[5]},open(sys.argv[1],'w'),indent=2)
PY
reason=verified
exit 0
