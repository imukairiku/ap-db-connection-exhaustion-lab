#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$ROOT"
COUNTER=artifacts/test-03/failure-state.json; LOCK=artifacts/test-03/.lock; mkdir -p artifacts/test-03
command -v flock >/dev/null || { echo 'TEST-03 FAIL: flock unavailable' >&2; exit 2; }
exec 9>"$LOCK"; flock -n 9 || { echo 'TEST-03 blocked: another run is active' >&2; exit 3; }
previous=$(python3 scripts/test03-counter.py "$COUNTER" gate) || { echo "TEST-03 blocked; counter=$COUNTER" >&2; exit 3; }
host=$(hostname); boot=$(cat /proc/sys/kernel/random/boot_id); qualified=1
[ -s /etc/killercoda/host ] || qualified=0
env_id="$host-$boot"; run_id="$(date -u +%Y%m%dT%H%M%S)-$$-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
art="artifacts/test-03/$env_id/$run_id"; mkdir -p "$art"
project="test03-$(printf %s "$run_id" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
compose_file="$ROOT/tests/test-03.compose.yml"; compose_kind=; started=0; finished=0; reason=unexpected_exit
prefix="test03-$run_id"

compose(){ if [ "$compose_kind" = plugin ]; then docker compose "$@"; else docker-compose "$@"; fi; }
cleanup(){
  local rc=0 c n v
  [ "$started" = 0 ] || compose -p "$project" -f "$compose_file" down --volumes --remove-orphans >"$art/cleanup.log" 2>&1 || rc=1
  c=$(docker ps -aq --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')
  n=$(docker network ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')
  v=$(docker volume ls -q --filter "label=com.docker.compose.project=$project" | wc -l | tr -d ' ')
  python3 - "$art/cleanup-verification.json" "$c" "$n" "$v" <<'PY' || rc=1
import json,sys
c,n,v=map(int,sys.argv[2:]); json.dump({'containers':c,'networks':n,'volumes':v,'verified':c==n==v==0},open(sys.argv[1],'w'),indent=2); raise SystemExit(0 if c==n==v==0 else 1)
PY
  return "$rc"
}
finalize(){
  local rc=$? status=FAIL count
  trap - EXIT INT TERM; [ "$finished" = 0 ] || exit "$rc"
  cleanup || { rc=1; reason=cleanup_failed; }; [ "$rc" = 0 ] && status=PASS
  count=$(python3 scripts/test03-counter.py "$COUNTER" finish "$run_id" "$art" "$status" "$reason") || exit 70
  python3 - "$art/summary.json" "$status" "$env_id" "$run_id" "$prefix" "$count" "$reason" <<'PY'
import json,sys
json.dump({'test_id':'TEST-03','status':sys.argv[2],'environment_id':sys.argv[3],'run_id':sys.argv[4],'request_id_prefix':sys.argv[5],'parallel_requests':12,'consecutive_failures':int(sys.argv[6]),'reason':sys.argv[7],'artifact_path':str(__import__('pathlib').Path(sys.argv[1]).parent)},open(sys.argv[1],'w'),indent=2)
PY
  finished=1
  if [ "$status" = PASS ]; then echo "TEST-03 PASS environment=$env_id run=$run_id parallel=12 ap_active=12 db_connections=12 committed=12 overflow_http=429 failures=$count artifact=$art"; else echo "TEST-03 FAIL reason=$reason failures=$count artifact=$art" >&2; fi
  exit "$rc"
}
trap finalize EXIT; trap 'reason=signal_INT; exit 130' INT; trap 'reason=signal_TERM; exit 143' TERM

[ "$qualified" = 1 ] || { reason=killercoda_marker_missing; exit 1; }
docker version >"$art/docker-version.txt" 2>&1 || { reason=docker_unavailable; exit 1; }
if docker compose version >"$art/compose-version.txt" 2>&1; then compose_kind=plugin
elif docker-compose version >"$art/compose-version.txt" 2>&1; then compose_kind=standalone
else reason=compose_unavailable; exit 1; fi
compose -p "$project" -f "$compose_file" config >"$art/compose-config.yml" || { reason=compose_config_failed; exit 1; }
started=1
compose -p "$project" -f "$compose_file" up -d --build db-server ap-server-1 >"$art/up.log" 2>&1 || { reason=compose_up_failed; exit 1; }
DB=$(compose -p "$project" -f "$compose_file" ps -q db-server); AP=$(compose -p "$project" -f "$compose_file" ps -q ap-server-1)
[ -n "$DB" ] && [ -n "$AP" ] || { reason=container_identity_failed; exit 1; }
for _ in $(seq 1 60); do
  db_health=$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null || true); ap_health=$(docker inspect -f '{{.State.Health.Status}}' "$AP" 2>/dev/null || true)
  [ "$db_health" = healthy ] && [ "$ap_health" = healthy ] && break; sleep 1
done
[ "$db_health" = healthy ] && [ "$ap_health" = healthy ] || { reason=health_timeout; exit 1; }
docker exec "$DB" psql -v ON_ERROR_STOP=1 -U lab -d lab -c 'CREATE TABLE business_results (request_id text PRIMARY KEY, committed_at timestamptz NOT NULL DEFAULT clock_timestamp())' >"$art/schema.log" 2>&1 || { reason=schema_setup_failed; exit 1; }
docker exec -i "$AP" python3 - "$prefix" >"$art/responses.json" 2>"$art/driver.stderr" <<'PY' &
import concurrent.futures,json,sys,urllib.request
prefix=sys.argv[1]
def invoke(index):
 body=json.dumps({'request_id':f'{prefix}-{index:02d}'}).encode(); request=urllib.request.Request('http://127.0.0.1:8080/work',data=body,headers={'Content-Type':'application/json'},method='POST')
 with urllib.request.urlopen(request,timeout=30) as response: return {'http_status':response.status,**json.loads(response.read())}
with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
 results=list(pool.map(invoke,range(1,13)))
print(json.dumps(results))
PY
driver_pid=$!
observed=0
for poll in $(seq 1 40); do
  docker exec -i "$AP" python3 - <<'PY' >"$art/ap-state-current.json"
import urllib.request
print(urllib.request.urlopen('http://127.0.0.1:8080/state',timeout=2).read().decode())
PY
  ap_active=$(python3 -c 'import json; print(json.load(open("'$art'/ap-state-current.json"))["active"])')
  db_connections=$(docker exec "$DB" psql -U lab -d lab -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name='ap-server-1' AND state='active'")
  printf '{"poll":%s,"ap_active":%s,"db_connections":%s}\n' "$poll" "$ap_active" "$db_connections" >>"$art/concurrency-polls.jsonl"
  if [ "$ap_active" = 12 ] && [ "$db_connections" = 12 ]; then observed=1; break; fi
  sleep 0.25
done
[ "$observed" = 1 ] || { reason=parallelism_not_observed; wait "$driver_pid" || true; exit 1; }
docker exec -i "$AP" python3 - "$prefix-overflow" >"$art/overflow-response.json" <<'PY' || { reason=overflow_probe_failed; wait "$driver_pid" || true; exit 1; }
import json,sys,urllib.error,urllib.request
body=json.dumps({'request_id':sys.argv[1]}).encode(); request=urllib.request.Request('http://127.0.0.1:8080/work',data=body,headers={'Content-Type':'application/json'},method='POST')
try: urllib.request.urlopen(request,timeout=3); raise SystemExit('overflow unexpectedly accepted')
except urllib.error.HTTPError as error: print(json.dumps({'http_status':error.code,**json.loads(error.read())})); raise SystemExit(0 if error.code==429 else 1)
PY
wait "$driver_pid" || { reason=parallel_requests_failed; exit 1; }
docker exec "$DB" psql -U lab -d lab -At -c "SELECT count(*) FROM business_results WHERE request_id LIKE '$prefix-%'" >"$art/committed-count.txt" || { reason=db_verification_failed; exit 1; }
docker logs "$AP" >"$art/ap.log" 2>&1 || { reason=ap_log_capture_failed; exit 1; }
python3 - "$art/responses.json" "$art/overflow-response.json" "$art/committed-count.txt" "$art/ap.log" "$prefix" <<'PY' || { reason=result_validation_failed; exit 1; }
import json,sys
responses=json.load(open(sys.argv[1])); overflow=json.load(open(sys.argv[2])); committed=int(open(sys.argv[3]).read()); prefix=sys.argv[5]
assert len(responses)==12 and all(x['http_status']==200 and x['status']=='SUCCESS' for x in responses)
assert len({x['request_id'] for x in responses})==12 and committed==12 and overflow['http_status']==429 and overflow['code']=='capacity_exceeded'
rows=[json.loads(x) for x in open(sys.argv[4]) if x.strip().startswith('{')]
for response in responses:
 assert [x['event'] for x in rows if x.get('request_id')==response['request_id']]==['START','DB_CONNECTED','COMMIT','SUCCESS']
PY
reason=verified
exit 0
