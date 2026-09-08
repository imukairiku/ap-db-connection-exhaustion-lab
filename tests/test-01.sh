#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$ROOT"
COUNTER=artifacts/test-01/failure-state.json
LOCK=artifacts/test-01/.lock
mkdir -p artifacts/test-01
command -v flock >/dev/null || { echo 'TEST-01 FAIL: flock unavailable' >&2; exit 2; }
exec 9>"$LOCK"; flock -n 9 || { echo "TEST-01 blocked: another run holds $LOCK" >&2; exit 3; }
previous=$(python3 scripts/test01-counter.py "$COUNTER" gate) || { echo "TEST-01 blocked; counter=$COUNTER" >&2; exit 3; }

host=$(hostname 2>/dev/null || printf unavailable)
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unavailable)
qualified=1; [ -s /etc/killercoda/host ] || qualified=0
env_id="$host-$boot"; [ "$qualified" = 1 ] || env_id="unqualified-$host-$boot"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
art="artifacts/test-01/$env_id/$run_id"; mkdir -p "$art" || exit 2
result="$art/result.jsonl"; ledger="$art/ownership-ledger.tsv"; : >"$result"; : >"$ledger"
project="test01-$(printf %s "$run_id" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
compose_file="$ROOT/tests/test-01.compose.yml"; compose_kind=
finished=0; resources_started=0; reason=unexpected_exit

event(){ python3 - "$result" "$1" "$2" "$3" "$env_id" "$run_id" "$art" "$previous" "${4:-}" <<'PY'
import datetime,json,sys
p,event,status,rc,env_id,run_id,art,count,end_count=sys.argv[1:]
row={'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'phase':'Phase 1','test_id':'TEST-01','event':event,'status':status,'rc':int(rc),'environment_id':env_id,'run_id':run_id,'command_id':'TEST-01-'+event,'artifact_path':art,'failure_count_at_start':int(count)}
if end_count:
 row['failure_count_at_end']=int(end_count); row['cleanup']=json.load(open(art+'/cleanup-verification.json'))
with open(p,'a',encoding='utf-8') as f: f.write(json.dumps(row,separators=(',',':'))+'\n')
PY
}
compose(){ if [ "$compose_kind" = plugin ]; then docker compose "$@"; else docker-compose "$@"; fi; }
cleanup(){
  local rc=0 containers networks volumes ledger_project ledger_file owned=1
  if [ "$resources_started" = 1 ]; then
    ledger_project=$(awk -F '\t' '$2=="project"{print $3; exit}' "$ledger")
    ledger_file=$(awk -F '\t' '$2=="project"{print $4; exit}' "$ledger")
    [ "$ledger_project" = "$project" ] && [ "$ledger_file" = "$compose_file" ] || owned=0
    while IFS=$'\t' read -r _ _ service id; do
      [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$id" 2>/dev/null)" = "$project" ] || owned=0
      [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$id" 2>/dev/null)" = "$service" ] || owned=0
    done < <(awk -F '\t' '$2=="container"{print}' "$ledger")
    while IFS=$'\t' read -r _ _ id _; do [ "$(docker network inspect -f '{{index .Labels "com.docker.compose.project"}}' "$id" 2>/dev/null)" = "$project" ] || owned=0; done < <(awk -F '\t' '$2=="network"{print}' "$ledger")
    while IFS=$'\t' read -r _ _ id _; do [ "$(docker volume inspect -f '{{index .Labels "com.docker.compose.project"}}' "$id" 2>/dev/null)" = "$project" ] || owned=0; done < <(awk -F '\t' '$2=="volume"{print}' "$ledger")
    if [ "$owned" = 1 ]; then compose -p "$ledger_project" -f "$ledger_file" down --volumes --remove-orphans >>"$art/cleanup.log" 2>&1 || rc=1
    else echo 'ownership ledger verification failed; refusing cleanup' >>"$art/cleanup.log"; rc=1; fi
  fi
  containers=$(docker ps -aq --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ') || rc=1
  networks=$(docker network ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ') || rc=1
  volumes=$(docker volume ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ') || rc=1
  python3 - "$art/cleanup-verification.json" "$containers" "$networks" "$volumes" <<'PY' || rc=1
import json,sys
p,c,n,v=sys.argv[1:]; json.dump({'containers':int(c),'networks':int(n),'volumes':int(v),'verified':int(c)==int(n)==int(v)==0},open(p,'w'),indent=2)
raise SystemExit(0 if int(c)==int(n)==int(v)==0 else 1)
PY
  while IFS=$'\t' read -r _ _ id _; do docker volume inspect "$id" >/dev/null 2>&1 && rc=1; done < <(awk -F '\t' '$2=="volume"{print}' "$ledger")
  python3 scripts/test01-phase0-inventory.py verify config/phase0-source.json "$art/phase0-protection.json" >>"$art/cleanup.log" 2>&1 || rc=1
  return "$rc"
}
finalize(){
  local rc=$? status=FAIL count anticipated
  trap - EXIT INT TERM
  if [ "$finished" = 1 ]; then exit "$rc"; fi
  cleanup || { rc=1; reason=cleanup_or_phase0_integrity_failed; }
  if [ "$rc" = 0 ]; then
    python3 - "$art" <<'PY' || { rc=1; reason=summary_generation_failed; }
import json,pathlib,sys
a=pathlib.Path(sys.argv[1]); context=json.loads((a/'execution-context.json').read_text()); settings=json.loads((a/'postgres-settings.json').read_text()); readiness=json.loads((a/'ap-readiness.json').read_text()); tcp=json.loads((a/'ap-db-tcp.json').read_text()); cleanup=json.loads((a/'cleanup-verification.json').read_text())
d={'schema_version':1,'test_id':'TEST-01','status':'PASS','environment_id':context['environment_id'],'run_id':context['run_id'],'compose_project':json.loads((a/'compose-ps.json').read_text())['db-server']['project'],'db_container_id':settings['db_container_id'],'ap_container_id':json.loads((a/'compose-ps.json').read_text())['ap-server-1']['id'],'max_connections':settings['max_connections'],'pg_postmaster_start_time':settings['pg_postmaster_start_time'],'db_restart_count':settings['db_restart_count'],'ap_ready':readiness['ready'],'ap_db_tcp':tcp,'ap_server_2_count':0,'ap_netadmin_count':0,'cleanup':cleanup,'artifact_path':str(a)}
(a/'summary.json').write_text(json.dumps(d,indent=2)+'\n',encoding='utf-8')
PY
  fi
  if [ "$rc" = 0 ]; then
    python3 scripts/test01-validate.py "$art" >"$art/validator.json" 2>>"$art/cleanup.log" || { rc=1; reason=artifact_validation_failed; }
  fi
  [ "$rc" = 0 ] && status=PASS
  [ "$status" = PASS ] && anticipated=0 || anticipated=$((previous+1))
  python3 - "$art/final-result-candidate.json" "$status" "$rc" "$anticipated" "$reason" <<'PY' || { echo "TEST-01 FAIL: candidate write failed artifact=$art" >&2; exit 70; }
import json,sys
json.dump({'status':sys.argv[2],'rc':int(sys.argv[3]),'failure_count_at_end':int(sys.argv[4]),'reason':sys.argv[5]},open(sys.argv[1],'w'),indent=2)
PY
  event test_result "$status" "$rc" "$anticipated" || { echo "TEST-01 FAIL: result write failed; counter unchanged artifact=$art" >&2; exit 70; }
  count=$(python3 scripts/test01-counter.py "$COUNTER" finish "$run_id" "$art" "$status" "$reason") || { echo "TEST-01 FAIL: counter update failed artifact=$art" >&2; exit 70; }
  [ "$count" = "$anticipated" ] || { echo "TEST-01 FAIL: counter/result mismatch artifact=$art" >&2; exit 70; }
  if [ "$status" = PASS ]; then
    python3 scripts/test01-validate.py "$art" "$COUNTER" >"$art/final-validator.json" 2>>"$art/cleanup.log" || { echo "TEST-01 FAIL: final validation failed artifact=$art" >&2; exit 70; }
  else
    python3 - "$result" "$COUNTER" "$run_id" "$count" "$art/final-validator.json" <<'PY' || { echo "TEST-01 FAIL: failure evidence validation failed artifact=$art" >&2; exit 70; }
import json,sys
result,counter,run_id,count,out=sys.argv[1:]
rows=[json.loads(line) for line in open(result,encoding='utf-8') if line.strip()]
state=json.load(open(counter,encoding='utf-8'))
terminal=[row for row in rows if row.get('event')=='test_result']
assert len(terminal)==1 and terminal[0]['status']=='FAIL' and terminal[0]['run_id']==run_id
assert terminal[0]['failure_count_at_end']==int(count)==state['consecutive_failures']
assert state['last_run_id']==run_id
with open(out,'w',encoding='utf-8') as stream:
 json.dump({'validated':True,'status':'FAIL','run_id':run_id,'failure_count':int(count)},stream,indent=2)
 stream.write('\n')
PY
  fi
  finished=1
  if [ "$status" = PASS ]; then echo "TEST-01 PASS environment=$env_id run=$run_id failures=$count artifact=$art"; else echo "TEST-01 FAIL reason=$reason failures=$count artifact=$art" >&2; fi
  exit "$rc"
}
trap finalize EXIT; trap 'reason=signal_INT; exit 130' INT; trap 'reason=signal_TERM; exit 143' TERM

event test_start START 0 || { reason=result_initialization_failed; exit 1; }
[ "$qualified" = 1 ] || { reason=killercoda_marker_missing; exit 1; }
marker_hash=$(python3 -c 'import hashlib; print(hashlib.sha256(open("/etc/killercoda/host","rb").read()).hexdigest())') || { reason=marker_hash_failed; exit 1; }
docker version >"$art/docker-version.txt" 2>&1 || { reason=docker_unavailable; exit 1; }
if docker compose version >"$art/compose-version.txt" 2>&1; then compose_kind=plugin
elif docker-compose version >"$art/compose-version.txt" 2>&1; then compose_kind=standalone
else reason=compose_unavailable; exit 1; fi
python3 - "$art/execution-context.json" "$env_id" "$run_id" "$host" "$boot" "$marker_hash" "$compose_kind" <<'PY' || { reason=context_write_failed; exit 1; }
import datetime,json,subprocess,sys
p,e,r,h,b,m,c=sys.argv[1:]; d={'schema_version':1,'environment':'killercoda','environment_id':e,'hostname':h,'boot_id':b,'marker_path':'/etc/killercoda/host','marker_sha256':m,'run_id':r,'docker_version':subprocess.check_output(['docker','version','--format','{{.Server.Version}}'],text=True).strip(),'compose_kind':c,'captured_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
with open(p,'w',encoding='utf-8') as f: json.dump(d,f,indent=2); f.write('\n')
PY
python3 scripts/test01-phase0-inventory.py capture config/phase0-source.json "$art/phase0-protection.json" || { reason=phase0_manifest_failed; exit 1; }
compose -p "$project" -f "$compose_file" config >"$art/compose-config.yaml" 2>"$art/compose-config.stderr" || { reason=compose_config_failed; exit 1; }
compose -p "$project" -f "$compose_file" config --services >"$art/compose-services.txt" || { reason=compose_services_failed; exit 1; }
[ "$(grep -cx db-server "$art/compose-services.txt")" = 1 ] && [ "$(grep -cx ap-server-1 "$art/compose-services.txt")" = 1 ] || { reason=required_service_missing; exit 1; }
! grep -Eq '^(ap-server-2|ap-netadmin-1)$' "$art/compose-services.txt" || { reason=out_of_scope_service_defined; exit 1; }
[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ] || { reason=project_collision; exit 1; }
compose -p "$project" -f "$compose_file" build db-server ap-server-1 >"$art/build.log" 2>&1 || { reason=compose_build_failed; exit 1; }
printf '%s\tproject\t%s\t%s\n' "$(date -u +%FT%TZ)" "$project" "$compose_file" >>"$ledger" || { reason=ownership_ledger_failed; exit 1; }
resources_started=1
compose -p "$project" -f "$compose_file" up -d db-server ap-server-1 >"$art/up.log" 2>&1 || { reason=compose_up_failed; exit 1; }
DB=$(compose -p "$project" -f "$compose_file" ps -q db-server); AP=$(compose -p "$project" -f "$compose_file" ps -q ap-server-1)
[ "$(printf '%s\n' "$DB" | grep -c .)" = 1 ] && [ "$(printf '%s\n' "$AP" | grep -c .)" = 1 ] || { reason=container_identity_failed; exit 1; }
printf '%s\tcontainer\tdb-server\t%s\n%s\tcontainer\tap-server-1\t%s\n' "$(date -u +%FT%TZ)" "$DB" "$(date -u +%FT%TZ)" "$AP" >>"$ledger" || { reason=ownership_ledger_failed; exit 1; }
while IFS= read -r resource; do [ -n "$resource" ] && printf '%s\tnetwork\t%s\t%s\n' "$(date -u +%FT%TZ)" "$resource" "$project" >>"$ledger"; done < <(docker network ls -q --filter "label=com.docker.compose.project=$project")
while IFS= read -r resource; do [ -n "$resource" ] && printf '%s\tvolume\t%s\t%s\n' "$(date -u +%FT%TZ)" "$resource" "$project" >>"$ledger"; done < <(docker volume ls -q --filter "label=com.docker.compose.project=$project")
compose -p "$project" -f "$compose_file" ps --format json >"$art/compose-ps.raw" 2>&1 || compose -p "$project" -f "$compose_file" ps >"$art/compose-ps.raw"
docker inspect "$DB" >"$art/db-inspect.json"; docker inspect "$AP" >"$art/ap-inspect.json"
python3 - "$art/compose-ps.json" "$art/db-inspect.json" "$art/ap-inspect.json" <<'PY' || { reason=compose_identity_failed; exit 1; }
import json,sys
out={}
for path in sys.argv[2:]:
 d=json.load(open(path))[0]; labels=d['Config']['Labels']; service=labels['com.docker.compose.service']; out[service]={'id':d['Id'],'service':service,'project':labels['com.docker.compose.project'],'running':d['State']['Running'],'health':d['State']['Health']['Status']}
json.dump(out,open(sys.argv[1],'w'),indent=2)
PY
for i in $(seq 1 60); do
  db_health=$(docker inspect -f '{{.State.Status}}/{{.State.Health.Status}}' "$DB" 2>/dev/null || printf unavailable)
  ap_health=$(docker inspect -f '{{.State.Status}}/{{.State.Health.Status}}' "$AP" 2>/dev/null || printf unavailable)
  python3 - "$art/health-polls.jsonl" "$i" "$db_health" "$ap_health" <<'PY'
import datetime,json,sys
with open(sys.argv[1],'a') as f: f.write(json.dumps({'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),'poll':int(sys.argv[2]),'db':sys.argv[3],'ap':sys.argv[4]})+'\n')
PY
  [ "$db_health" = running/healthy ] && [ "$ap_health" = running/healthy ] && break
  sleep 1
done
[ "$db_health" = running/healthy ] && [ "$ap_health" = running/healthy ] || { reason=health_timeout; exit 1; }
# Refresh normalized evidence after the readiness gate; the earlier raw inspection
# may legitimately have captured Docker's transient "starting" state.
docker inspect "$DB" >"$art/db-inspect.json"; docker inspect "$AP" >"$art/ap-inspect.json"
python3 - "$art/compose-ps.json" "$art/db-inspect.json" "$art/ap-inspect.json" <<'PY' || { reason=compose_identity_failed_after_health; exit 1; }
import json,sys
out={}
for path in sys.argv[2:]:
 d=json.load(open(path))[0]; labels=d['Config']['Labels']; service=labels['com.docker.compose.service']; out[service]={'id':d['Id'],'service':service,'project':labels['com.docker.compose.project'],'running':d['State']['Running'],'health':d['State']['Health']['Status']}
json.dump(out,open(sys.argv[1],'w'),indent=2)
PY
[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$project" --filter label=com.docker.compose.service=ap-netadmin-1)" ] || { reason=netadmin_started; exit 1; }
[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$project" --filter label=com.docker.compose.service=ap-server-2)" ] || { reason=ap_server_2_present; exit 1; }
docker exec "$DB" psql -U lab -d lab -At -F $'\t' -c "SHOW max_connections; SELECT pg_postmaster_start_time();" >"$art/postgres-settings.raw" 2>&1 || { reason=postgres_observation_failed; exit 1; }
restart=$(docker inspect -f '{{.RestartCount}}' "$DB")
python3 - "$art/postgres-settings.raw" "$art/postgres-settings.json" "$restart" "$DB" <<'PY' || { reason=postgres_settings_invalid; exit 1; }
import json,sys
lines=[x.strip() for x in open(sys.argv[1]) if x.strip()]; assert len(lines)==2 and int(lines[0])==20 and lines[1]
json.dump({'max_connections':int(lines[0]),'pg_postmaster_start_time':lines[1],'db_restart_count':int(sys.argv[3]),'db_container_id':sys.argv[4]},open(sys.argv[2],'w'),indent=2)
PY
docker exec -i "$AP" python3 - <<'PY' >"$art/ap-readiness.json" || { reason=ap_readiness_failed; exit 1; }
import json,urllib.request
with urllib.request.urlopen('http://127.0.0.1:8080/health',timeout=3) as r:
 d=json.loads(r.read()); assert r.status==200 and d.get('ready') is True; print(json.dumps({'http_status':r.status,'ready':True,'body':d}))
PY
docker exec -i "$AP" python3 - <<'PY' >"$art/ap-db-tcp.json" || { reason=ap_db_tcp_failed; exit 1; }
import datetime,json,socket,time
started=datetime.datetime.now(datetime.timezone.utc).isoformat(); t=time.monotonic(); ip=socket.gethostbyname('db-server'); s=socket.create_connection(('db-server',5432),3); s.close()
print(json.dumps({'status':'CONNECTED','resolved_ip':ip,'port':5432,'started_at':started,'finished_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'elapsed_seconds':time.monotonic()-t}))
PY
reason=verified
exit 0
