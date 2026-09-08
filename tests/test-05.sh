#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$ROOT"
COUNTER=artifacts/test-05/failure-state.json; LOCK=artifacts/test-05/.lock; mkdir -p artifacts/test-05
command -v flock >/dev/null || { echo 'TEST-05 FAIL: flock unavailable' >&2; exit 2; }
exec 9>"$LOCK"; flock -n 9 || { echo 'TEST-05 blocked: another run is active' >&2; exit 3; }
previous=$(python3 scripts/test05-counter.py "$COUNTER" gate) || { echo "TEST-05 blocked; counter=$COUNTER" >&2; exit 3; }
host=$(hostname); boot=$(cat /proc/sys/kernel/random/boot_id); qualified=1; [ -s /etc/killercoda/host ] || qualified=0
env_id="$host-$boot"; run_id="$(date -u +%Y%m%dT%H%M%S)-$$-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
art="artifacts/test-05/$env_id/$run_id"; mkdir -p "$art"; : >"$art/cleanup-backend-actions.jsonl"
project="test05-$(printf %s "$run_id" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"; tag="t05_$(printf %s "$run_id" | tr -cd 'a-zA-Z0-9' | tail -c 20)"
compose_file="$ROOT/tests/test-04.compose.yml"; compose_kind=; started=0; output_rule=0; input_rule=0; paused=0; finished=0; reason=unexpected_exit
DB=; AP=; ADMIN=; DB_IP=
compose(){ if [ "$compose_kind" = plugin ]; then docker compose "$@"; else docker-compose "$@"; fi; }
snapshot(){
 local name=$1
 docker exec "$DB" psql -U lab -d lab -At -F '|' -c "SELECT pid,client_addr,client_port,backend_start,state FROM pg_stat_activity WHERE application_name='ap-server-1' ORDER BY pid" >"$art/$name-pg.txt" || return 1
 docker exec "$DB" ss -Hnt state established '( sport = :5432 )' >"$art/$name-ss.txt" || return 1
 python3 scripts/test04-snapshot.py "$art/$name-pg.txt" "$art/$name-ss.txt" "$art/$name.json"
}
cleanup(){
 local rc=0 c n v terminate_result
 if [ "$started" = 1 ]; then
  if [ "$paused" = 1 ]; then docker unpause "$AP" >>"$art/cleanup.log" 2>&1 && paused=0 || rc=1; fi
  if [ "$output_rule" = 1 ]; then docker exec "$ADMIN" iptables -D OUTPUT -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$tag" -j DROP >>"$art/cleanup.log" 2>&1 && output_rule=0 || rc=1; fi
  if [ "$input_rule" = 1 ]; then docker exec "$ADMIN" iptables -D INPUT -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$tag" -j DROP >>"$art/cleanup.log" 2>&1 && input_rule=0 || rc=1; fi
  if ! docker exec "$ADMIN" iptables-save >"$art/iptables-cleanup.txt"; then rc=1
  elif grep -Fq "$tag" "$art/iptables-cleanup.txt"; then rc=1; fi
  if [ -s "$art/before.json" ] && [ -n "$DB" ]; then
   python3 - "$art/before.json" >"$art/pids-to-clean.txt" <<'PY'
import json,sys
for row in json.load(open(sys.argv[1]))['pg_rows']: print('|'.join(map(str,(row['pid'],row['backend_start'],'ap-server-1',row['client_addr'],row['client_port']))))
PY
   while IFS='|' read -r pid backend_start application_name client_addr client_port; do
    terminate_result=$(docker exec -i "$DB" psql -U lab -d lab -At -v ON_ERROR_STOP=1 -v pid="$pid" -v backend_start="$backend_start" -v application_name="$application_name" -v client_addr="$client_addr" -v client_port="$client_port" < scripts/cleanup-backend.sql 2>>"$art/cleanup-backend-stderr.log") || rc=1
    python3 - "$art/cleanup-backend-actions.jsonl" "$pid" "$terminate_result" <<'PY' || rc=1
import json,sys
try: result=json.loads(sys.argv[3])
except Exception: result={'action':'SQL_ERROR','raw':sys.argv[3]}
with open(sys.argv[1],'a') as stream: stream.write(json.dumps({'requested_pid':int(sys.argv[2]),'db_result':result})+'\n')
raise SystemExit(0 if result.get('action') in ('TERMINATED','SKIPPED_GONE') and (result.get('action')!='TERMINATED' or result.get('terminated') is True) else 1)
PY
   done <"$art/pids-to-clean.txt"
   gone=0
   for _ in $(seq 1 20); do snapshot cleanup-current || { rc=1; break; }; python3 - "$art/before.json" "$art/cleanup-current.json" <<'PY' && { gone=1; break; }
import json,sys
b=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2])); bp={x['pid'] for x in b['pg_rows']}; cp={x['pid'] for x in c['pg_rows']}; bt={(x['db_addr'],x['db_port'],x['client_addr'],x['client_port']) for x in b['tcp_tuples']}; ct={(x['db_addr'],x['db_port'],x['client_addr'],x['client_port']) for x in c['tcp_tuples']}; assert not bp&cp and not bt&ct
PY
    sleep 0.5
   done
   [ "$gone" = 1 ] || rc=1
   python3 - "$art/before.json" "$art/cleanup-current.json" "$art/baseline.json" "$DB" "$art/connection-cleanup.json" <<'PY' || rc=1
import json,subprocess,sys
b=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2])); base=json.load(open(sys.argv[3])); bp={x['pid'] for x in b['pg_rows']}; cp={x['pid'] for x in c['pg_rows']}; bt={(x['db_addr'],x['db_port'],x['client_addr'],x['client_port']) for x in b['tcp_tuples']}; ct={(x['db_addr'],x['db_port'],x['client_addr'],x['client_port']) for x in c['tcp_tuples']}; pm=subprocess.check_output(['docker','exec',sys.argv[4],'psql','-U','lab','-d','lab','-At','-c','SELECT pg_postmaster_start_time()'],text=True).strip(); restart=int(subprocess.check_output(['docker','inspect','-f','{{.RestartCount}}',sys.argv[4]],text=True))
json.dump({'remaining_pids':sorted(bp&cp),'remaining_tuples':sorted(bt&ct),'postmaster':pm,'restart_count':restart,'postmaster_unchanged':pm==base['postmaster'] and restart==base['restart_count']},open(sys.argv[5],'w'),indent=2)
PY
  fi
  compose -p "$project" -f "$compose_file" down --volumes --remove-orphans >>"$art/cleanup.log" 2>&1 || rc=1
 fi
 c=$(docker ps -aq --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' '); n=$(docker network ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' '); v=$(docker volume ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')
 python3 - "$art/resource-cleanup.json" "$c" "$n" "$v" <<'PY' || rc=1
import json,sys
c,n,v=map(int,sys.argv[2:]); json.dump({'containers':c,'networks':n,'volumes':v,'verified':c==n==v==0},open(sys.argv[1],'w'),indent=2); raise SystemExit(0 if c==n==v==0 else 1)
PY
 return "$rc"
}
finalize(){
 local rc=$? status=FAIL count i=0 f=0 s=0
 trap - EXIT INT TERM; [ "$finished" = 0 ] || exit "$rc"; cleanup || { rc=1; reason=cleanup_failed; }
 if [ "$rc" = 0 ]; then python3 scripts/test05-validate.py "$art" || { rc=1; reason=artifact_validation_failed; }; fi
 [ "$rc" = 0 ] && status=PASS
 for pair in immediate_after:i after_5s:f after_15s:s; do name=${pair%:*}; var=${pair#*:}; [ ! -f "$art/$name.json" ] || printf -v "$var" %s "$(python3 -c 'import json; print(json.load(open("'$art'/'$name'.json"))["matched_count"])')"; done
 count=$(python3 scripts/test05-counter.py "$COUNTER" finish "$run_id" "$art" "$status" "$reason") || exit 70
 python3 - "$art/summary.json" "$status" "$env_id" "$run_id" "$i" "$f" "$s" "$count" "$reason" <<'PY'
import json,sys
json.dump({'test_id':'TEST-05','status':sys.argv[2],'environment_id':sys.argv[3],'run_id':sys.argv[4],'method':'A','matched':{'immediate_after':int(sys.argv[5]),'after_5s':int(sys.argv[6]),'after_15s':int(sys.argv[7])},'consecutive_failures':int(sys.argv[8]),'reason':sys.argv[9],'artifact_path':str(__import__('pathlib').Path(sys.argv[1]).parent)},open(sys.argv[1],'w'),indent=2)
PY
 finished=1
 if [ "$status" = PASS ]; then echo "TEST-05 PASS environment=$env_id run=$run_id method=A immediate=$i after_5s=$f after_15s=$s pg_ss_residual=true postmaster_unchanged=true cleanup_pg=0 cleanup_ss=0 failures=$count artifact=$art"; else echo "TEST-05 FAIL reason=$reason failures=$count artifact=$art" >&2; fi
 exit "$rc"
}
trap finalize EXIT; trap 'reason=signal_INT; exit 130' INT; trap 'reason=signal_TERM; exit 143' TERM
[ "$qualified" = 1 ] || { reason=killercoda_marker_missing; exit 1; }
docker version >"$art/docker-version.txt" 2>&1 || { reason=docker_unavailable; exit 1; }
if docker compose version >"$art/compose-version.txt" 2>&1; then compose_kind=plugin; elif docker-compose version >"$art/compose-version.txt" 2>&1; then compose_kind=standalone; else reason=compose_unavailable; exit 1; fi
python3 scripts/test01-phase0-inventory.py capture config/test01-phase0-prerequisite.json "$art/phase0-prerequisite.json" || { reason=phase0_prerequisite_invalid; exit 1; }
compose -p "$project" -f "$compose_file" config >"$art/compose-config.yml" || { reason=compose_config_failed; exit 1; }; started=1
compose -p "$project" -f "$compose_file" up -d --build db-server ap-server-1 ap-netadmin-1 >"$art/up.log" 2>&1 || { reason=compose_up_failed; exit 1; }
DB=$(compose -p "$project" -f "$compose_file" ps -q db-server); AP=$(compose -p "$project" -f "$compose_file" ps -q ap-server-1); ADMIN=$(compose -p "$project" -f "$compose_file" ps -q ap-netadmin-1); [ -n "$DB" ] && [ -n "$AP" ] && [ -n "$ADMIN" ] || { reason=container_identity_failed; exit 1; }
for _ in $(seq 1 60); do dh=$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null||true); ah=$(docker inspect -f '{{.State.Health.Status}}' "$AP" 2>/dev/null||true); [ "$dh" = healthy ] && [ "$ah" = healthy ] && break; sleep 1; done; [ "$dh" = healthy ] && [ "$ah" = healthy ] || { reason=health_timeout; exit 1; }
PM=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); RESTART=$(docker inspect -f '{{.RestartCount}}' "$DB"); python3 - "$art/baseline.json" "$PM" "$RESTART" <<'PY'
import json,sys
json.dump({'postmaster':sys.argv[2],'restart_count':int(sys.argv[3])},open(sys.argv[1],'w'),indent=2)
PY
prefix="test05-$run_id"; docker exec -i "$AP" python3 - "$prefix" <<'PY' >"$art/batch-response.json" || { reason=batch_start_failed; exit 1; }
import json,sys,urllib.request
ids=[f'{sys.argv[1]}-{n:02d}' for n in range(1,13)]; request=urllib.request.Request('http://127.0.0.1:8080/batch',data=json.dumps({'request_ids':ids}).encode(),headers={'Content-Type':'application/json'},method='POST')
with urllib.request.urlopen(request,timeout=5) as response: print(json.dumps({'http_status':response.status,**json.loads(response.read())}))
PY
ready=0; for _ in $(seq 1 60); do docker exec -i "$AP" python3 - <<'PY' >"$art/ap-state.json"
import urllib.request
print(urllib.request.urlopen('http://127.0.0.1:8080/state',timeout=2).read().decode())
PY
read -r a c w < <(python3 -c 'import json; d=json.load(open("'$art'/ap-state.json")); print(d["active"],d["connected"],d["waiting"])'); [ "$a" = 12 ] && [ "$c" = 12 ] && [ "$w" = 12 ] && { ready=1; break; }; sleep .25; done
[ "$ready" = 1 ] || { reason=batch_not_ready; exit 1; }; snapshot before || { reason=before_snapshot_failed; exit 1; }; [ "$(python3 -c 'import json; print(json.load(open("'$art'/before.json"))["matched_count"])')" = 12 ] || { reason=before_not_12; exit 1; }
DB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DB")
docker exec "$ADMIN" iptables -I OUTPUT 1 -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$tag" -j DROP || { reason=output_drop_failed; exit 1; }; output_rule=1
docker exec "$ADMIN" iptables -I INPUT 1 -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$tag" -j DROP || { reason=input_drop_failed; exit 1; }; input_rule=1
docker exec "$ADMIN" iptables-save >"$art/iptables-after.txt"; [ "$(grep -c -- "$tag" "$art/iptables-after.txt")" = 2 ] || { reason=drop_verification_failed; exit 1; }
docker pause "$AP" >/dev/null || { reason=pause_failed; exit 1; }; paused=1; [ "$(docker inspect -f '{{.State.Paused}}' "$AP")" = true ] || { reason=pause_not_observed; exit 1; }
observe(){ local name=$1; snapshot "$name" || return 1; pm=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); restart=$(docker inspect -f '{{.RestartCount}}' "$DB"); python3 - "$art/$name-state.json" "$pm" "$restart" <<'PY'
import json,sys
json.dump({'ap_paused':True,'postmaster':sys.argv[2],'restart_count':int(sys.argv[3])},open(sys.argv[1],'w'),indent=2)
PY
}
observe immediate_after || { reason=immediate_observation_failed; exit 1; }; sleep 5; observe after_5s || { reason=after_5s_observation_failed; exit 1; }; sleep 10; observe after_15s || { reason=after_15s_observation_failed; exit 1; }
reason=verified
exit 0
