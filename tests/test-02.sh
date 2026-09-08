#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$ROOT"
COUNTER=artifacts/test-02/failure-state.json; LOCK=artifacts/test-02/.lock
mkdir -p artifacts/test-02
command -v flock >/dev/null || { echo 'TEST-02 FAIL: flock unavailable' >&2; exit 2; }
exec 9>"$LOCK"; flock -n 9 || { echo 'TEST-02 blocked: another run is active' >&2; exit 3; }
previous=$(python3 scripts/test02-counter.py "$COUNTER" gate) || { echo "TEST-02 blocked; counter=$COUNTER" >&2; exit 3; }

host=$(hostname); boot=$(cat /proc/sys/kernel/random/boot_id); qualified=1
[ -s /etc/killercoda/host ] || qualified=0
env_id="$host-$boot"; run_id="$(date -u +%Y%m%dT%H%M%S)-$$-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
art="artifacts/test-02/$env_id/$run_id"; mkdir -p "$art"
project="test02-$(printf %s "$run_id" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
compose_file="$ROOT/tests/test-02.compose.yml"; compose_kind=; started=0; finished=0; reason=unexpected_exit
request_id="test02-$run_id"

compose(){ if [ "$compose_kind" = plugin ]; then docker compose "$@"; else docker-compose "$@"; fi; }
cleanup(){
  local rc=0 containers networks volumes
  [ "$started" = 0 ] || compose -p "$project" -f "$compose_file" down --volumes --remove-orphans >"$art/cleanup.log" 2>&1 || rc=1
  containers=$(docker ps -aq --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')
  networks=$(docker network ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')
  volumes=$(docker volume ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')
  python3 - "$art/cleanup-verification.json" "$containers" "$networks" "$volumes" <<'PY' || rc=1
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
  [ "$rc" = 0 ] && status=PASS
  count=$(python3 scripts/test02-counter.py "$COUNTER" finish "$run_id" "$art" "$status" "$reason") || exit 70
  python3 - "$art/summary.json" "$status" "$env_id" "$run_id" "$request_id" "$count" "$reason" <<'PY'
import json,sys
json.dump({'test_id':'TEST-02','status':sys.argv[2],'environment_id':sys.argv[3],'run_id':sys.argv[4],'request_id':sys.argv[5],'consecutive_failures':int(sys.argv[6]),'reason':sys.argv[7],'artifact_path':str(__import__('pathlib').Path(sys.argv[1]).parent)},open(sys.argv[1],'w'),indent=2)
PY
  finished=1
  if [ "$status" = PASS ]; then echo "TEST-02 PASS environment=$env_id run=$run_id request_id=$request_id failures=$count artifact=$art"; else echo "TEST-02 FAIL reason=$reason failures=$count artifact=$art" >&2; fi
  exit "$rc"
}
trap finalize EXIT; trap 'reason=signal_INT; exit 130' INT; trap 'reason=signal_TERM; exit 143' TERM

[ "$qualified" = 1 ] || { reason=killercoda_marker_missing; exit 1; }
docker version >"$art/docker-version.txt" 2>&1 || { reason=docker_unavailable; exit 1; }
if docker compose version >"$art/compose-version.txt" 2>&1; then compose_kind=plugin
elif docker-compose version >"$art/compose-version.txt" 2>&1; then compose_kind=standalone
else reason=compose_unavailable; exit 1; fi
compose -p "$project" -f "$compose_file" config >"$art/compose-config.yml" || { reason=compose_config_failed; exit 1; }
[ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ] || { reason=project_collision; exit 1; }
started=1
compose -p "$project" -f "$compose_file" up -d --build db-server ap-server-1 >"$art/up.log" 2>&1 || { reason=compose_up_failed; exit 1; }
DB=$(compose -p "$project" -f "$compose_file" ps -q db-server); AP=$(compose -p "$project" -f "$compose_file" ps -q ap-server-1)
[ -n "$DB" ] && [ -n "$AP" ] || { reason=container_identity_failed; exit 1; }
for _ in $(seq 1 60); do
  db_health=$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null || true)
  ap_health=$(docker inspect -f '{{.State.Health.Status}}' "$AP" 2>/dev/null || true)
  [ "$db_health" = healthy ] && [ "$ap_health" = healthy ] && break
  sleep 1
done
[ "$db_health" = healthy ] && [ "$ap_health" = healthy ] || { reason=health_timeout; exit 1; }
docker exec "$DB" psql -v ON_ERROR_STOP=1 -U lab -d lab -c 'CREATE TABLE business_results (request_id text PRIMARY KEY, committed_at timestamptz NOT NULL DEFAULT clock_timestamp())' >"$art/schema.log" 2>&1 || { reason=schema_setup_failed; exit 1; }
docker exec -i "$AP" python3 - "$request_id" >"$art/work-response.json" <<'PY' || { reason=work_request_failed; exit 1; }
import json,sys,urllib.request
body=json.dumps({'request_id':sys.argv[1]}).encode()
request=urllib.request.Request('http://127.0.0.1:8080/work',data=body,headers={'Content-Type':'application/json'},method='POST')
with urllib.request.urlopen(request,timeout=15) as response:
 document=json.loads(response.read()); document['http_status']=response.status; print(json.dumps(document))
PY
docker exec "$DB" psql -U lab -d lab -At -c "SELECT count(*) FROM business_results WHERE request_id = '$request_id'" >"$art/db-committed-count.txt" || { reason=db_verification_failed; exit 1; }
docker logs "$AP" >"$art/ap.log" 2>&1 || { reason=ap_log_capture_failed; exit 1; }
python3 - "$art/work-response.json" "$art/db-committed-count.txt" "$art/ap.log" "$request_id" <<'PY' || { reason=business_verification_failed; exit 1; }
import json,sys
response=json.load(open(sys.argv[1])); count=int(open(sys.argv[2]).read().strip()); request_id=sys.argv[4]
events=[json.loads(line)['event'] for line in open(sys.argv[3]) if line.strip().startswith('{') and json.loads(line).get('request_id')==request_id]
assert response=={'request_id':request_id,'status':'SUCCESS','http_status':200}
assert count==1 and events==['START','DB_CONNECTED','COMMIT','SUCCESS']
PY
reason=verified
exit 0
