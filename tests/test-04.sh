#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$ROOT"
COUNTER=artifacts/test-04/failure-state.json; LOCK=artifacts/test-04/.lock; mkdir -p artifacts/test-04
command -v flock >/dev/null || { echo 'TEST-04 FAIL: flock unavailable' >&2; exit 2; }
exec 9>"$LOCK"; flock -n 9 || { echo 'TEST-04 blocked: another run is active' >&2; exit 3; }
previous=$(python3 scripts/test04-counter.py "$COUNTER" gate) || { echo "TEST-04 blocked; counter=$COUNTER" >&2; exit 3; }
host=$(hostname); boot=$(cat /proc/sys/kernel/random/boot_id); qualified=1; [ -s /etc/killercoda/host ] || qualified=0
env_id="$host-$boot"; run_id="$(date -u +%Y%m%dT%H%M%S)-$$-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
art="artifacts/test-04/$env_id/$run_id"; mkdir -p "$art"; : >"$art/injection-ledger.tsv"
project="test04-$(printf %s "$run_id" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"; tag="t04_$(printf %s "$run_id" | tr -cd 'a-zA-Z0-9' | tail -c 20)"
compose_file="$ROOT/tests/test-04.compose.yml"; compose_kind=; started=0; output_rule=0; input_rule=0; paused=0; finished=0; reason=unexpected_exit
compose(){ if [ "$compose_kind" = plugin ]; then docker compose "$@"; else docker-compose "$@"; fi; }
cleanup(){
 local rc=0 c n v
 if [ "$started" = 1 ]; then
  [ "$paused" = 0 ] || docker unpause "$AP" >>"$art/cleanup.log" 2>&1 || rc=1
  [ "$output_rule" = 0 ] || docker exec "$ADMIN" iptables -D OUTPUT -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$tag" -j DROP >>"$art/cleanup.log" 2>&1 || rc=1
  [ "$input_rule" = 0 ] || docker exec "$ADMIN" iptables -D INPUT -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$tag" -j DROP >>"$art/cleanup.log" 2>&1 || rc=1
  if [ "$output_rule" = 1 ] || [ "$input_rule" = 1 ]; then docker exec "$ADMIN" iptables-save | grep -Fq "$tag" && rc=1; fi
  compose -p "$project" -f "$compose_file" down --volumes --remove-orphans >>"$art/cleanup.log" 2>&1 || rc=1
 fi
 c=$(docker ps -aq --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' '); n=$(docker network ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' '); v=$(docker volume ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')
 python3 - "$art/cleanup-verification.json" "$c" "$n" "$v" <<'PY' || rc=1
import json,sys
c,n,v=map(int,sys.argv[2:]); json.dump({'containers':c,'networks':n,'volumes':v,'verified':c==n==v==0},open(sys.argv[1],'w'),indent=2); raise SystemExit(0 if c==n==v==0 else 1)
PY
 return "$rc"
}
finalize(){
 local rc=$? status=FAIL count matched=0
 trap - EXIT INT TERM; [ "$finished" = 0 ] || exit "$rc"; cleanup || { rc=1; reason=cleanup_failed; }; [ "$rc" = 0 ] && status=PASS
 [ ! -f "$art/before.json" ] || matched=$(python3 -c 'import json; print(json.load(open("'$art'/before.json"))["matched_count"])')
 count=$(python3 scripts/test04-counter.py "$COUNTER" finish "$run_id" "$art" "$status" "$reason") || exit 70
 python3 - "$art/summary.json" "$status" "$env_id" "$run_id" "$matched" "$count" "$reason" <<'PY'
import json,sys
json.dump({'test_id':'TEST-04','status':sys.argv[2],'environment_id':sys.argv[3],'run_id':sys.argv[4],'method':'A','connections_processing_at_injection':int(sys.argv[5]),'consecutive_failures':int(sys.argv[6]),'reason':sys.argv[7],'artifact_path':str(__import__('pathlib').Path(sys.argv[1]).parent)},open(sys.argv[1],'w'),indent=2)
PY
 finished=1
 if [ "$status" = PASS ]; then echo "TEST-04 PASS environment=$env_id run=$run_id method=A processing=12 pg=12 ss=12 matched=12 rules=2 ap_state=PAUSED db_running=true postmaster_unchanged=true failures=$count artifact=$art"; else echo "TEST-04 FAIL reason=$reason failures=$count artifact=$art" >&2; fi
 exit "$rc"
}
trap finalize EXIT; trap 'reason=signal_INT; exit 130' INT; trap 'reason=signal_TERM; exit 143' TERM
[ "$qualified" = 1 ] || { reason=killercoda_marker_missing; exit 1; }
docker version >"$art/docker-version.txt" 2>&1 || { reason=docker_unavailable; exit 1; }
if docker compose version >"$art/compose-version.txt" 2>&1; then compose_kind=plugin; elif docker-compose version >"$art/compose-version.txt" 2>&1; then compose_kind=standalone; else reason=compose_unavailable; exit 1; fi
compose -p "$project" -f "$compose_file" config >"$art/compose-config.yml" || { reason=compose_config_failed; exit 1; }
started=1; compose -p "$project" -f "$compose_file" up -d --build db-server ap-server-1 ap-netadmin-1 >"$art/up.log" 2>&1 || { reason=compose_up_failed; exit 1; }
DB=$(compose -p "$project" -f "$compose_file" ps -q db-server); AP=$(compose -p "$project" -f "$compose_file" ps -q ap-server-1); ADMIN=$(compose -p "$project" -f "$compose_file" ps -q ap-netadmin-1)
[ -n "$DB" ] && [ -n "$AP" ] && [ -n "$ADMIN" ] || { reason=container_identity_failed; exit 1; }
for _ in $(seq 1 60); do db_health=$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null || true); ap_health=$(docker inspect -f '{{.State.Health.Status}}' "$AP" 2>/dev/null || true); [ "$db_health" = healthy ] && [ "$ap_health" = healthy ] && break; sleep 1; done
[ "$db_health" = healthy ] && [ "$ap_health" = healthy ] || { reason=health_timeout; exit 1; }
PM_BEFORE=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); RESTART_BEFORE=$(docker inspect -f '{{.RestartCount}}' "$DB")
prefix="test04-$run_id"; docker exec -i "$AP" python3 - "$prefix" >"$art/batch-response.json" <<'PY' || { reason=batch_start_failed; exit 1; }
import json,sys,urllib.request
ids=[f'{sys.argv[1]}-{n:02d}' for n in range(1,13)]; body=json.dumps({'request_ids':ids}).encode(); request=urllib.request.Request('http://127.0.0.1:8080/batch',data=body,headers={'Content-Type':'application/json'},method='POST')
with urllib.request.urlopen(request,timeout=5) as response: print(json.dumps({'http_status':response.status,**json.loads(response.read())}))
PY
ready=0
for _ in $(seq 1 60); do
 docker exec -i "$AP" python3 - <<'PY' >"$art/ap-state.json"
import urllib.request
print(urllib.request.urlopen('http://127.0.0.1:8080/state',timeout=2).read().decode())
PY
 read -r active connected waiting < <(python3 -c 'import json; d=json.load(open("'$art'/ap-state.json")); print(d["active"],d["connected"],d["waiting"])')
 [ "$active" = 12 ] && [ "$connected" = 12 ] && [ "$waiting" = 12 ] && { ready=1; break; }; sleep 0.25
done
[ "$ready" = 1 ] || { reason=batch_not_ready; exit 1; }
docker exec "$DB" psql -U lab -d lab -At -F '|' -c "SELECT pid,client_addr,client_port,backend_start,state FROM pg_stat_activity WHERE application_name='ap-server-1' ORDER BY pid" >"$art/pg-before.txt" || { reason=pg_snapshot_failed; exit 1; }
docker exec "$DB" ss -Hnt state established '( sport = :5432 )' >"$art/ss-before.txt" || { reason=ss_snapshot_failed; exit 1; }
python3 scripts/test04-snapshot.py "$art/pg-before.txt" "$art/ss-before.txt" "$art/before.json" || { reason=snapshot_parse_failed; exit 1; }
python3 - "$art/ap-state.json" "$art/before.json" <<'PY' || { reason=processing_connections_not_12; exit 1; }
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); assert a['active']==a['connected']==a['waiting']==12 and len(a['requests'])==12; assert b['pg_count']==b['matched_count']==12
PY
docker logs "$AP" >"$art/ap-before.log" 2>&1; ! grep -Eq '"event": "?(COMMIT|ROLLBACK|SUCCESS|FAILURE)"?' "$art/ap-before.log" || { reason=request_completed_before_injection; exit 1; }
printf '1\tSNAPSHOT_VERIFIED\n' >>"$art/injection-ledger.tsv"
DB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DB")
docker exec "$ADMIN" iptables -I OUTPUT 1 -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$tag" -j DROP || { reason=output_drop_failed; exit 1; }; output_rule=1; printf '2\tOUTPUT_DROP\n' >>"$art/injection-ledger.tsv"
docker exec "$ADMIN" iptables -I INPUT 1 -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$tag" -j DROP || { reason=input_drop_failed; exit 1; }; input_rule=1; printf '3\tINPUT_DROP\n' >>"$art/injection-ledger.tsv"
docker exec "$ADMIN" iptables-save >"$art/iptables-after.txt"; [ "$(grep -c -- "$tag" "$art/iptables-after.txt")" = 2 ] || { reason=drop_verification_failed; exit 1; }; printf '4\tRULES_VERIFIED\n' >>"$art/injection-ledger.tsv"
docker pause "$AP" >"$art/pause.txt" || { reason=pause_failed; exit 1; }; paused=1; printf '5\tPAUSE\n' >>"$art/injection-ledger.tsv"
[ "$(docker inspect -f '{{.State.Paused}}' "$AP")" = true ] || { reason=pause_not_observed; exit 1; }; printf '6\tPAUSE_VERIFIED\n' >>"$art/injection-ledger.tsv"
docker exec "$DB" pg_isready -U lab -d lab >"$art/db-after.txt" || { reason=db_not_running; exit 1; }
PM_AFTER=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); RESTART_AFTER=$(docker inspect -f '{{.RestartCount}}' "$DB")
[ "$PM_BEFORE" = "$PM_AFTER" ] && [ "$RESTART_BEFORE" = "$RESTART_AFTER" ] || { reason=db_restarted; exit 1; }
python3 - "$art/db-continuity.json" "$PM_BEFORE" "$PM_AFTER" "$RESTART_BEFORE" "$RESTART_AFTER" <<'PY'
import json,sys
json.dump({'postmaster_before':sys.argv[2],'postmaster_after':sys.argv[3],'restart_before':int(sys.argv[4]),'restart_after':int(sys.argv[5]),'unchanged':sys.argv[2]==sys.argv[3] and sys.argv[4]==sys.argv[5]},open(sys.argv[1],'w'),indent=2)
PY
reason=verified
exit 0
