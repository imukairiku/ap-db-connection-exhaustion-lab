#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$ROOT"
COUNTER=artifacts/test-10/failure-state.json; LOCK=artifacts/test-10/.lock; mkdir -p artifacts/test-10 artifacts/phase4
command -v flock >/dev/null || { echo 'TEST-10 FAIL: flock unavailable' >&2; exit 2; }
exec 9>"$LOCK"; flock -n 9 || { echo 'TEST-10 blocked: another run is active' >&2; exit 3; }
python3 scripts/phase4-counter.py TEST-10 "$COUNTER" gate >/dev/null || exit 3
host=$(hostname); boot=$(cat /proc/sys/kernel/random/boot_id); env_id="$host-$boot"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
art="artifacts/test-10/$env_id/$run_id"; mkdir -p "$art"
project="test10-$(printf %s "$run_id" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
tag="t10_$(printf %s "$run_id" | tr -cd 'a-zA-Z0-9' | tail -c 20)"
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
  if [ "$rc" = 0 ]; then python3 scripts/test10-validate.py "$art" || { rc=1; reason=validation_failed; }; fi
  if [ "$rc" = 0 ]; then
    python3 - "$art" "$env_id" "$run_id" <<'PY' || { rc=1; reason=pointer_write_failed; }
import json,os,pathlib,sys
art,env,run=sys.argv[1:]; target=pathlib.Path('artifacts/phase4/test10-current.json'); temp=target.with_name(target.name+'.tmp-'+str(os.getpid()))
temp.write_text(json.dumps({'schema_version':1,'environment_id':env,'run_id':run,'artifact_path':art,'test_id':'TEST-10','status':'PASS'},indent=2)+'\n',encoding='utf-8'); os.replace(temp,target)
PY
  fi
  [ "$rc" = 0 ] && status=PASS
  count=$(python3 scripts/phase4-counter.py TEST-10 "$COUNTER" finish "$run_id" "$art" "$status" "$reason") || exit 70
  finished=1
  if [ "$status" = PASS ]; then
    echo "TEST-10 PASS environment=$env_id run=$run_id old_before=10 old_after=0 new_preserved=true management_preserved=true ap2_business_committed=true failures=$count artifact=$art"
  else echo "TEST-10 FAIL reason=$reason failures=$count artifact=$art" >&2; fi
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
DB_ID_BEFORE=$(docker inspect -f '{{.Id}}' "$DB")
python3 scripts/test08-monitor.py "$project" "$file" "$kind" "$AP1" "$run_id" "$art/failover-state.json" "$art/monitor-events.jsonl" >"$art/monitor.stdout" 2>"$art/monitor.stderr" & monitor_pid=$!
for _ in $(seq 1 40); do
  [ -f "$art/failover-state.json" ] && grep -q '"status": "PRIMARY_ACTIVE"' "$art/failover-state.json" && break
  kill -0 "$monitor_pid" 2>/dev/null || break
  sleep .25
done
[ -f "$art/failover-state.json" ] && grep -q '"status": "PRIMARY_ACTIVE"' "$art/failover-state.json" || { reason=monitor_not_ready; exit 1; }
batch(){
  docker exec -i "$1" python3 - "$2" "$3" <<'PY'
import json,sys,urllib.request
ids=[f'{sys.argv[1]}-{n:02d}' for n in range(1,int(sys.argv[2])+1)]
request=urllib.request.Request('http://127.0.0.1:8080/batch',data=json.dumps({'request_ids':ids}).encode(),headers={'Content-Type':'application/json'},method='POST')
print(urllib.request.urlopen(request,timeout=5).read().decode())
PY
}
snapshot(){
  docker exec "$DB" psql -U lab -d lab -At -F '|' -c "SELECT application_name,pid,client_addr,client_port,backend_start,state_change,state FROM pg_stat_activity WHERE application_name IN ('ap-server-1','ap-server-2','management-1','management-2') ORDER BY pid" >"$1"
}
batch "$AP1" "test10-old-$run_id" 10 >"$art/ap1-batch.json" || { reason=old_batch_failed; exit 1; }
for _ in $(seq 1 60); do
  snapshot "$art/old-ready.raw" || { reason=old_snapshot_failed; exit 1; }
  [ "$(grep -c '^ap-server-1|' "$art/old-ready.raw")" = 10 ] && [ "$(grep -c '^management-' "$art/old-ready.raw")" = 2 ] && break
  sleep .25
done
[ "$(grep -c '^ap-server-1|' "$art/old-ready.raw")" = 10 ] && [ "$(grep -c '^management-' "$art/old-ready.raw")" = 2 ] || { reason=old_or_management_not_ready; exit 1; }
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
batch "$AP2" "test10-new-$run_id" 12 >"$art/ap2-batch.json" || { reason=new_batch_failed; exit 1; }
settled=0
for _ in $(seq 1 60); do
  docker exec -i "$AP2" python3 - <<'PY' >"$art/ap2-state.json"
import urllib.request
print(urllib.request.urlopen('http://127.0.0.1:8080/state',timeout=2).read().decode())
PY
  read -r connected failed < <(python3 - "$art/ap2-state.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); print(d['connected'],d['failed'])
PY
)
  [ "$connected" -ge 1 ] && [ "$failed" -ge 1 ] && [ $((connected+failed)) = 12 ] && { settled=1; break; }
  sleep .25
done
[ "$settled" = 1 ] || { reason=new_requests_not_settled; exit 1; }
docker logs "$DB" >"$art/db.log" 2>&1 || { reason=db_log_unavailable; exit 1; }
grep -Eq 'remaining connection slots|too many clients' "$art/db.log" || { reason=db_capacity_failure_not_observed; exit 1; }
snapshot "$art/before.raw" || { reason=before_snapshot_failed; exit 1; }
AP1_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$AP1")
python3 scripts/test10-terminate.py "$DB" "$art/before.raw" "$AP1_IP" "$art/termination.json" || { reason=targeted_termination_failed; exit 1; }
for _ in $(seq 1 40); do
  snapshot "$art/after.raw" || { reason=after_snapshot_failed; exit 1; }
  [ "$(grep -c '^ap-server-1|' "$art/after.raw")" = 0 ] && break
  sleep .25
done
[ "$(grep -c '^ap-server-1|' "$art/after.raw")" = 0 ] || { reason=old_connections_remain; exit 1; }
request_id="test10-recovered-$run_id"
docker exec -i "$AP2" python3 - "$request_id" <<'PY' >"$art/business-id.txt" || { reason=ap2_business_failed; exit 1; }
import os,psycopg2,sys
rid=sys.argv[1]
with psycopg2.connect(host=os.environ['DB_HOST'],user='app_user',password='app-only',dbname='lab',application_name=os.environ['AP_NAME'],connect_timeout=5) as conn:
    with conn.cursor() as cursor:
        cursor.execute('INSERT INTO business_results(request_id,ap_name) VALUES(%s,%s)',(rid,os.environ['AP_NAME']))
print(rid)
PY
docker exec "$DB" psql -U lab -d lab -At -F '|' -c "SELECT request_id,ap_name FROM business_results WHERE request_id='$request_id'" >"$art/business-verified.txt" || { reason=business_readback_failed; exit 1; }
PM2=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); RESTART2=$(docker inspect -f '{{.RestartCount}}' "$DB")
DB_ID_AFTER=$(docker inspect -f '{{.Id}}' "$(compose -p "$project" -f "$file" ps -q db-server)")
python3 - "$art/db-continuity.json" "$PM" "$PM2" "$RESTART" "$RESTART2" "$DB_ID_BEFORE" "$DB_ID_AFTER" <<'PY' || { reason=continuity_write_failed; exit 1; }
import json,sys
path,pm,pm2,r,r2,db,db2=sys.argv[1:]
json.dump({'postmaster_before':pm,'postmaster_after':pm2,'restart_before':int(r),'restart_after':int(r2),'container_before':db,'container_after':db2},open(path,'w'),indent=2)
PY
python3 scripts/test10-summarize.py "$art" || { reason=recovery_validation_failed; exit 1; }
reason=verified
exit 0
