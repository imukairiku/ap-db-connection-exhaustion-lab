#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$ROOT"
COUNTER=artifacts/test-12/failure-state.json; LOCK=artifacts/test-12/.lock; mkdir -p artifacts/test-12
command -v flock >/dev/null || { echo 'TEST-12 FAIL: flock unavailable' >&2; exit 2; }
exec 9>"$LOCK"; flock -n 9 || { echo 'TEST-12 blocked: another run is active' >&2; exit 3; }
python3 scripts/phase5-counter.py TEST-12 "$COUNTER" gate >/dev/null || exit 3
env_id="$(hostname)-$(cat /proc/sys/kernel/random/boot_id)"
run_id="$(date -u +%Y%m%dT%H%M%S)-$$-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
art="artifacts/test-12/$env_id/$run_id"; mkdir -p "$art"
project="test12-$(printf %s "$run_id" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-')"
tag="t12_$(printf %s "$run_id" | tr -cd 'a-zA-Z0-9' | tail -c 20)"
file="$ROOT/tests/test-12.compose.yml"
kind=; started=0; out_rule=0; in_rule=0; paused=0; reason=unexpected_exit; DB=; AP=; ADMIN=; DB_IP=
compose(){ if [ "$kind" = plugin ]; then docker compose "$@"; else docker-compose "$@"; fi; }
snapshot(){
  docker exec "$DB" psql -U lab -d lab -At -F '|' -c "SELECT pid,client_addr,client_port,backend_start,state FROM pg_stat_activity WHERE application_name='ap-server-1' ORDER BY pid" >"$art/$1-pg.txt" || return 1
  docker exec "$DB" ss -Hnt state established '( sport = :5432 )' >"$art/$1-ss.txt" || return 1
  python3 scripts/test04-snapshot.py "$art/$1-pg.txt" "$art/$1-ss.txt" "$art/$1.json"
}
cleanup(){
  local rc=0 c n v
  if [ "$started" = 1 ]; then
    if [ "$paused" = 1 ]; then docker unpause "$AP" >>"$art/cleanup.log" 2>&1 || rc=1; fi
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
  if [ "$rc" = 0 ]; then python3 scripts/test12-validate.py "$art" || { rc=1; reason=validation_failed; }; fi
  [ "$rc" = 0 ] && status=PASS
  count=$(python3 scripts/phase5-counter.py TEST-12 "$COUNTER" finish "$run_id" "$art" "$status" "$reason") || exit 70
  if [ "$status" = PASS ]; then
    seconds=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["elapsed_seconds"])' "$art/measurement.json")
    echo "TEST-12 PASS environment=$env_id run=$run_id method=A keepalive=20/5/3 old_before=3 old_after=0 pg_ss_gone=true release_seconds=$seconds postmaster_unchanged=true failures=$count artifact=$art"
  else echo "TEST-12 FAIL reason=$reason failures=$count artifact=$art" >&2; fi
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
DB=$(compose -p "$project" -f "$file" ps -q db-server); AP=$(compose -p "$project" -f "$file" ps -q ap-server-1); ADMIN=$(compose -p "$project" -f "$file" ps -q ap-netadmin-1)
[ -n "$DB" ] && [ -n "$AP" ] && [ -n "$ADMIN" ] || { reason=identity_failed; exit 1; }
for _ in $(seq 1 60); do
  dh=$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null || true)
  ah=$(docker inspect -f '{{.State.Health.Status}}' "$AP" 2>/dev/null || true)
  [ "$dh" = healthy ] && [ "$ah" = healthy ] && break
  sleep 1
done
[ "$dh" = healthy ] && [ "$ah" = healthy ] || { reason=readiness_timeout; exit 1; }
docker exec "$DB" psql -U lab -d lab -At -F '|' -c 'SHOW tcp_keepalives_idle; SHOW tcp_keepalives_interval; SHOW tcp_keepalives_count' >"$art/keepalive-settings.txt" || { reason=keepalive_query_failed; exit 1; }
PM=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); RESTART=$(docker inspect -f '{{.RestartCount}}' "$DB")
docker exec -i "$AP" python3 - "test12-$run_id" <<'PY' >"$art/ap1-batch.json" || { reason=batch_failed; exit 1; }
import json,sys,urllib.request
ids=[f'{sys.argv[1]}-{n:02d}' for n in range(1,4)]
q=urllib.request.Request('http://127.0.0.1:8080/batch',data=json.dumps({'request_ids':ids}).encode(),headers={'Content-Type':'application/json'},method='POST')
print(urllib.request.urlopen(q,timeout=5).read().decode())
PY
for _ in $(seq 1 60); do
  snapshot before || { reason=before_snapshot_failed; exit 1; }
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["matched_count"])' "$art/before.json")" = 3 ] && break
  sleep .25
done
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["matched_count"])' "$art/before.json")" = 3 ] || { reason=old_connections_not_ready; exit 1; }
DB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DB")
docker exec "$ADMIN" iptables -I OUTPUT 1 -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$tag" -j DROP || { reason=output_drop_failed; exit 1; }; out_rule=1
docker exec "$ADMIN" iptables -I INPUT 1 -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$tag" -j DROP || { reason=input_drop_failed; exit 1; }; in_rule=1
docker exec "$ADMIN" iptables-save >"$art/iptables-after.txt"
[ "$(grep -c -- "$tag" "$art/iptables-after.txt")" = 2 ] || { reason=drop_verification_failed; exit 1; }
docker pause "$AP" >/dev/null || { reason=pause_failed; exit 1; }; paused=1
start_ms=$(date +%s%3N)
snapshot immediate || { reason=immediate_snapshot_failed; exit 1; }
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["matched_count"])' "$art/immediate.json")" = 3 ] || { reason=no_initial_residual; exit 1; }
released=0
for _ in $(seq 1 100); do
  sleep 1
  snapshot current || { reason=poll_failed; exit 1; }
  read -r pg ss < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["pg_count"],d["ss_count"])' "$art/current.json")
  printf '%s\t%s\t%s\n' "$(date +%s%3N)" "$pg" "$ss" >>"$art/poll.tsv"
  if [ "$pg" = 0 ] && [ "$ss" = 0 ]; then released=1; break; fi
done
[ "$released" = 1 ] || { reason=keepalive_release_timeout; exit 1; }
end_ms=$(date +%s%3N)
PM2=$(docker exec "$DB" psql -U lab -d lab -At -c 'SELECT pg_postmaster_start_time()'); RESTART2=$(docker inspect -f '{{.RestartCount}}' "$DB")
python3 - "$art/measurement.json" "$start_ms" "$end_ms" "$PM" "$PM2" "$RESTART" "$RESTART2" <<'PY' || { reason=measurement_write_failed; exit 1; }
import json,sys
path,start,end,pm,pm2,r,r2=sys.argv[1:]
json.dump({'start_ms':int(start),'end_ms':int(end),'elapsed_seconds':round((int(end)-int(start))/1000,3),'postmaster_before':pm,'postmaster_after':pm2,'restart_before':int(r),'restart_after':int(r2)},open(path,'w'),indent=2)
PY
reason=verified
exit 0
