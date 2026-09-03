#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
[ "$#" -eq 0 ] || { echo 'ERROR: probe-env.sh takes no arguments' >&2; exit 2; }
detect_environment() {
  if [ -s /etc/killercoda/host ]; then
    echo killercoda
  else
    echo local
  fi
}
DETECTED_ENVIRONMENT=$(detect_environment)
ENVIRONMENT=$DETECTED_ENVIRONMENT
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
[ -n "$BOOT_ID" ] || { echo 'ERROR: cannot read kernel boot_id' >&2; exit 2; }
ENV_ID="$(hostname)-$BOOT_ID"
SAFE_ID=$(printf '%s' "$ENV_ID" | tr -cd 'a-zA-Z0-9_.-')
PROJECT="phase0-${SAFE_ID,,}"
PROJECT=${PROJECT:0:55}
FAIL_COUNT_FILE="artifacts/phase0/test-00-failures.json"
SEED_FILE="docs/phase0-test-state.json"
SEED_FAILURES=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["known_consecutive_failures"]))' "$SEED_FILE")
PREVIOUS_FAILURES=$(python3 - "$FAIL_COUNT_FILE" "$SEED_FAILURES" <<'PY'
import json,sys
try: print(int(json.load(open(sys.argv[1]))['consecutive_failures']))
except Exception: print(int(sys.argv[2]))
PY
)
ATTEMPT=$((PREVIOUS_FAILURES + 1))
if [ "$PREVIOUS_FAILURES" -ge 3 ]; then
  latest=$(find "artifacts/phase0/$SAFE_ID" -mindepth 2 -maxdepth 2 -name result.jsonl -type f 2>/dev/null | sort | tail -n 1)
  echo "[Phase 0] TEST-00 blocked after $PREVIOUS_FAILURES consecutive failures; no artifact was created or changed." >&2
  echo "[Phase 0] Counter: $FAIL_COUNT_FILE" >&2
  [ -z "$latest" ] || echo "[Phase 0] Latest preserved evidence: $latest" >&2
  exit 3
fi
initial_fail() {
  local reason=$1
  python3 - "$FAIL_COUNT_FILE" "$ENV_ID" "$reason" "$SEED_FAILURES" <<'PY'
import datetime,json,os,sys
p,env_id,reason,seed=sys.argv[1:]
try: old=json.load(open(p,encoding='utf-8'))
except Exception: old={'consecutive_failures':int(seed)}
count=int(old.get('consecutive_failures',int(seed)))+1
tmp=p+'.tmp'
with open(tmp,'w',encoding='utf-8') as f:
 json.dump({'test_id':'TEST-00','consecutive_failures':count,'last_environment_id':env_id,'last_reason':reason,'updated_at':datetime.datetime.now(datetime.timezone.utc).isoformat()},f,indent=2); f.write('\n')
os.replace(tmp,p)
print(f'[Phase 0] TEST-00 FAIL #{count}: {reason} (counter: {p})',file=sys.stderr)
PY
}
RUN_BASE=$(date -u +%Y%m%dT%H%M%S)-$$
RUN_ID=$RUN_BASE
run_suffix=0
while [ -e "artifacts/phase0/$SAFE_ID/run-$RUN_ID" ]; do
  run_suffix=$((run_suffix + 1))
  RUN_ID="$RUN_BASE-$run_suffix"
done
ART="artifacts/phase0/$SAFE_ID/run-$RUN_ID"
RESULT="$ART/result.jsonl"
LEDGER="$ART/cleanup-ledger.tsv"
mkdir -p "$ART" config || { initial_fail "failed to create run artifact directory: $ART"; exit 70; }
: >"$RESULT" || { initial_fail "failed to initialize result artifact: $RESULT"; exit 70; }
: >"$LEDGER" || { initial_fail "failed to initialize cleanup ledger: $LEDGER"; exit 70; }
export PHASE0_PROJECT="$PROJECT"
HOST=$(hostname); KERNEL=$(uname -sr)
DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unavailable)
COMPOSE_KIND=unavailable; COMPOSE_VERSION=unavailable
if docker compose version >"$ART/compose-version.txt" 2>&1; then
  COMPOSE_KIND=plugin
  COMPOSE_VERSION=$(head -n 1 "$ART/compose-version.txt")
elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >"$ART/compose-version.txt" 2>&1; then
  COMPOSE_KIND=standalone
  COMPOSE_VERSION=$(head -n 1 "$ART/compose-version.txt")
fi
export PHASE0_COMPOSE_KIND="$COMPOSE_KIND"
SEQ=0; CLEANED=0; ABORTED=0; FAILURE_RECORDED=0; TEST_STARTED=0; ROLLBACK_ARMED=0; ROLLBACK_FAILED=0
CONFIG_TARGET=config/selected-method.json
CONFIG_BACKUP="config/.selected-method.backup-$RUN_ID"
BACKUP_META="$ART/config-backup-metadata.json"
DB= AP= NETADMIN= DB_IP= TAG=; ACTIVE_METHOD=; BEFORE_FILE=; RULE_KIND=; MUTATION=
ORIGINAL_LINK_FILE= ORIGINAL_QDISC_FILE=

progress() { printf '[Phase 0] %s\n' "$*"; }
compose() { if [ "$COMPOSE_KIND" = plugin ]; then docker compose "$@"; else docker-compose "$@"; fi; }
record_failure() {
  [ "$FAILURE_RECORDED" = 0 ] || return 0
  FAILURE_RECORDED=1
  python3 - "$FAIL_COUNT_FILE" "$ENV_ID" "$1" "$SEED_FAILURES" <<'PY'
import datetime,json,os,sys
p,env_id,reason,seed=sys.argv[1:]
try: old=json.load(open(p,encoding='utf-8'))
except Exception: old={'consecutive_failures':int(seed)}
count=int(old.get('consecutive_failures',int(seed)))+1
tmp=p+'.tmp'
json.dump({'test_id':'TEST-00','consecutive_failures':count,'last_environment_id':env_id,'last_reason':reason,'updated_at':datetime.datetime.now(datetime.timezone.utc).isoformat()},open(tmp,'w',encoding='utf-8'),indent=2)
open(tmp,'a').write('\n'); os.replace(tmp,p)
print(f'[Phase 0] TEST-00 FAIL #{count}: {reason} (counter: {p})',file=sys.stderr)
PY
}
record_success() { python3 - "$FAIL_COUNT_FILE" <<'PY'
import datetime,json,os,sys
p=sys.argv[1]; tmp=p+'.tmp'; json.dump({'test_id':'TEST-00','consecutive_failures':0,'updated_at':datetime.datetime.now(datetime.timezone.utc).isoformat()},open(tmp,'w'),indent=2); open(tmp,'a').write('\n'); os.replace(tmp,p)
PY
}

if [ -n "${PHASE0_ENVIRONMENT:-}${PHASE0_ENVIRONMENT_ID:-}${PHASE0_ATTEMPT:-}" ]; then
  record_failure 'environment/identity/attempt overrides are forbidden'
  exit 2
fi

KILLERCODA_HOST_HASH=
if [ "$ENVIRONMENT" = killercoda ]; then
  KILLERCODA_HOST_HASH=$(python3 -c 'import hashlib; print(hashlib.sha256(open("/etc/killercoda/host","rb").read()).hexdigest())') || { record_failure 'cannot hash Killercoda host marker'; exit 2; }
fi

python3 - "$ART/execution-context.json" "$ENVIRONMENT" "$ENV_ID" "$RUN_ID" "$KILLERCODA_HOST_HASH" "$BOOT_ID" "$DOCKER_VERSION" "$COMPOSE_KIND" "$COMPOSE_VERSION" <<'PY' || { record_failure "failed to write execution context; evidence directory: $ART"; exit 70; }
import datetime,json,os,platform
import sys
p,environment,environment_id,run_id,marker_hash,boot_id,docker_version,compose_kind,compose_version=sys.argv[1:]
data={'schema_version':1,'context':environment,'context_id':environment_id,'run_id':run_id,'context_source':'/etc/killercoda/host' if environment=='killercoda' else 'local','killercoda_host_sha256':marker_hash,'hostname':platform.node(),'boot_id':boot_id,'kernel':platform.release(),'docker_version':docker_version,'compose_kind':compose_kind,'compose_version':compose_version,'captured_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
with open(p,'w',encoding='utf-8') as f: json.dump(data,f,indent=2); f.write('\n')
PY
progress "context=$ENVIRONMENT id=$ENV_ID detected=$DETECTED_ENVIRONMENT"
progress "Docker=$DOCKER_VERSION Compose=$COMPOSE_KIND ($COMPOSE_VERSION)"

json_event() {
  local event=$1 status=$2 rc=$3 extra
  if [ "$#" -ge 4 ]; then extra=$4; else extra='{}'; fi
  SEQ=$((SEQ+1))
  python3 - "$RESULT" "$event" "$status" "$rc" "$extra" "$SEQ" \
    "$ENVIRONMENT" "$ENV_ID" "$HOST" "$KERNEL" "$DOCKER_VERSION" \
    "$COMPOSE_VERSION" "$ATTEMPT" "$RUN_ID" "$ART" <<'PY'
import datetime,json,sys
p,event,status,rc,extra,seq,environment,environment_id,hostname,kernel,docker_version,compose_version,attempt,run_id,artifact_path=sys.argv[1:]
parsed=json.loads(extra)
if not isinstance(parsed,dict): raise TypeError('extra must be a JSON object')
base=dict(ts=datetime.datetime.now(datetime.timezone.utc).isoformat(),phase='Phase 0',test_id='TEST-00',event=event,status=status,rc=int(rc),environment=environment,environment_id=environment_id,run_id=run_id,hostname=hostname,kernel=kernel,docker_version=docker_version,compose_version=compose_version,attempt=int(attempt),command_id=f'cmd-{seq}',artifact_path=artifact_path)
base.update(parsed)
with open(p,'a',encoding='utf-8') as f: f.write(json.dumps(base,separators=(',',':'))+'\n')
PY
}

verify_backup() {
  python3 - "$CONFIG_BACKUP" "$BACKUP_META" <<'PY'
import hashlib,json,sys
backup,meta_path=sys.argv[1:]
raw=open(backup,'rb').read(); meta=json.load(open(meta_path,encoding='utf-8'))
assert hashlib.sha256(raw).hexdigest()==meta['sha256']
assert json.loads(raw)==meta['identity']
PY
}

arm_config_rollback() {
  ROLLBACK_ARMED=1
  python3 - "$CONFIG_TARGET" "$BACKUP_META" <<'PY' || return 1
import hashlib,json,os,sys
target,meta_path=sys.argv[1:]
data={'schema_version':1,'target':target,'original_present':os.path.isfile(target)}
if data['original_present']:
 raw=open(target,'rb').read(); data['sha256']=hashlib.sha256(raw).hexdigest(); data['identity']=json.loads(raw)
with open(meta_path,'w',encoding='utf-8') as f: json.dump(data,f,indent=2); f.write('\n')
PY
  if [ -f "$CONFIG_TARGET" ]; then
    mv "$CONFIG_TARGET" "$CONFIG_BACKUP" || return 1
    verify_backup || return 1
  fi
  # A path appearing after the atomic backup is a concurrent update; never overwrite it.
  [ ! -e "$CONFIG_TARGET" ] || return 1
}

rollback_config() {
  [ "$ROLLBACK_ARMED" = 1 ] || return 0
  local belongs=1 concurrent=0
  if [ -f "$CONFIG_TARGET" ]; then
    python3 - "$CONFIG_TARGET" "$ENV_ID" "$ATTEMPT" "$RESULT" <<'PY' || belongs=0
import json,sys
p,environment_id,attempt,evidence=sys.argv[1:]
d=json.load(open(p,encoding='utf-8'))
raise SystemExit(0 if d.get('environment_id')==environment_id and d.get('attempt')==int(attempt) and d.get('evidence_artifact')==evidence else 1)
PY
    if [ "$belongs" = 1 ]; then
      rm -f -- "$CONFIG_TARGET" || ROLLBACK_FAILED=1
      [ ! -e "$CONFIG_TARGET" ] || ROLLBACK_FAILED=1
    elif [ -e "$CONFIG_BACKUP" ]; then
      concurrent=1
      ROLLBACK_FAILED=1
    fi
  fi
  if [ "$concurrent" = 0 ] && [ ! -e "$CONFIG_TARGET" ] && [ -e "$CONFIG_BACKUP" ]; then
    verify_backup || ROLLBACK_FAILED=1
    if [ "$ROLLBACK_FAILED" = 0 ]; then
      mv "$CONFIG_BACKUP" "$CONFIG_TARGET" || ROLLBACK_FAILED=1
      [ -f "$CONFIG_TARGET" ] || ROLLBACK_FAILED=1
      if [ "$ROLLBACK_FAILED" = 0 ]; then
        python3 - "$CONFIG_TARGET" "$BACKUP_META" <<'PY' || ROLLBACK_FAILED=1
import hashlib,json,sys
target,meta_path=sys.argv[1:]
raw=open(target,'rb').read(); meta=json.load(open(meta_path,encoding='utf-8'))
assert hashlib.sha256(raw).hexdigest()==meta['sha256'] and json.loads(raw)==meta['identity']
PY
      fi
    fi
  fi
  if [ -n "${tmp:-}" ] && [ -e "$tmp" ]; then
    rm -f -- "$tmp" || ROLLBACK_FAILED=1
    [ ! -e "$tmp" ] || ROLLBACK_FAILED=1
  fi
  ROLLBACK_ARMED=0
  if [ "$ROLLBACK_FAILED" = 1 ]; then
    echo "[Phase 0] CRITICAL: config rollback refused or failed; target=$CONFIG_TARGET backup=$CONFIG_BACKUP" >&2
    return 1
  fi
  return 0
}

finalize_config_commit() {
  python3 - "$CONFIG_TARGET" "$ENV_ID" "$RUN_ID" "$ATTEMPT" "$RESULT" <<'PY' || return 1
import json,sys
p,environment_id,run_id,attempt,evidence=sys.argv[1:]
d=json.load(open(p,encoding='utf-8'))
assert d.get('environment_id')==environment_id and d.get('run_id')==run_id
assert d.get('attempt')==int(attempt) and d.get('evidence_artifact')==evidence
PY
  # The new config is now authoritative. A stale backup is non-fatal evidence,
  # and must never cause rollback of this already-validated config.
  ROLLBACK_ARMED=0
  if [ -e "$CONFIG_BACKUP" ]; then
    if ! verify_backup || ! rm -f -- "$CONFIG_BACKUP" || [ -e "$CONFIG_BACKUP" ]; then
      python3 - "$ART/config-backup-cleanup-warning.json" "$CONFIG_BACKUP" "$CONFIG_TARGET" <<'PY' || true
import datetime,json,sys
p,backup,target=sys.argv[1:]
with open(p,'w',encoding='utf-8') as f:
 json.dump({'status':'WARNING','reason':'validated new config committed; old backup cleanup failed','backup':backup,'target':target,'ts':datetime.datetime.now(datetime.timezone.utc).isoformat()},f,indent=2); f.write('\n')
PY
      echo "[Phase 0] WARNING: committed config is valid, but old backup remains: $CONFIG_BACKUP" >&2
    fi
  fi
  return 0
}

fail_exit() {
  local reason=$1 rc=${2:-1} artifact=${3:-$RESULT} extra
  rollback_config || true
  [ "$ROLLBACK_FAILED" = 0 ] || reason="$reason; selected config rollback FAILED"
  extra=$(python3 - "$reason" "$artifact" <<'PY'
import json,sys
print(json.dumps({'reason':sys.argv[1],'artifact_path':sys.argv[2]},separators=(',',':')))
PY
  ) || { record_failure "$reason; evidence: $artifact"; exit "$rc"; }
  json_event test_result FAIL "$rc" "$extra" || true
  record_failure "$reason; evidence: $artifact"
  exit "$rc"
}

required_event() {
  local name=$1
  if ! json_event "$@"; then
    fail_exit "required JSONL event write failed: $name" 70 "$RESULT"
  fi
}

stop_state() {
  case "$1" in
    A) [ "$(docker inspect -f '{{.State.Paused}}' "$AP" 2>/dev/null)" = true ] && echo PAUSED || echo RUNNING ;;
    B) docker top "$AP" -eo stat 2>/dev/null | tail -n +2 | awk 'NF{n++; if ($1 !~ /^T/) bad=1} END{exit !(n>0 && !bad)}' && echo STOPPED || echo RUNNING ;;
    C) docker inspect -f '{{.State.Running}}' "$AP" 2>/dev/null | grep -q true && echo RUNNING || echo EXITED/ABSENT ;;
    D|E) [ "$(docker inspect -f '{{.State.Paused}}' "$AP" 2>/dev/null)" = true ] && echo PAUSED || echo RUNNING ;;
  esac
}

record_before_state() {
  local method=$1 inspect_file="$ART/method-$method-before-inspect.json" ps_file="$ART/method-$method-before-ps.txt"
  docker inspect "$AP" >"$inspect_file" 2>&1 || return 1
  docker top "$AP" -eo pid,stat,comm >"$ps_file" 2>&1 || return 1
  python3 - "$inspect_file" "$ps_file" <<'PY'
import json,sys
state=json.load(open(sys.argv[1],encoding='utf-8'))[0]['State']
rows=[x.split() for x in open(sys.argv[2],encoding='utf-8').read().splitlines()[1:] if x.split()]
assert state.get('Running') is True and state.get('Paused') is False
assert rows and all(len(r)>1 and not r[1].startswith(('T','Z','X')) for r in rows)
PY
}

remove_mutation() {
  [ -n "$NETADMIN" ] || return 0
  local failed=0 identifier=$TAG
  case "$MUTATION" in
    iptables)
      docker exec "$NETADMIN" iptables -D OUTPUT -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$TAG" -j DROP >/dev/null 2>&1 || failed=1
      docker exec "$NETADMIN" iptables -D INPUT -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$TAG" -j DROP >/dev/null 2>&1 || failed=1
      docker exec "$NETADMIN" iptables-save | grep -Fq "$TAG" && failed=1 ;;
    nft) docker exec "$NETADMIN" nft delete table inet "$TAG" >/dev/null 2>&1 || failed=1; docker exec "$NETADMIN" nft list table inet "$TAG" >/dev/null 2>&1 && failed=1 ;;
    link)
      identifier=$ORIGINAL_LINK_FILE
      [ -s "$ORIGINAL_LINK_FILE" ] || failed=1
      grep -qx up "$ORIGINAL_LINK_FILE" || failed=1
      docker exec "$NETADMIN" ip link set eth0 up >/dev/null 2>&1 || failed=1
      docker exec "$NETADMIN" cat /sys/class/net/eth0/operstate >"$ART/method-$ACTIVE_METHOD-link-after.txt" 2>&1 || failed=1
      cmp -s "$ORIGINAL_LINK_FILE" "$ART/method-$ACTIVE_METHOD-link-after.txt" || failed=1 ;;
    tc)
      identifier=$ORIGINAL_QDISC_FILE
      [ -s "$ORIGINAL_QDISC_FILE" ] || failed=1
      docker exec "$NETADMIN" tc qdisc del dev eth0 root >/dev/null 2>&1 || failed=1
      docker exec "$NETADMIN" tc qdisc show dev eth0 >"$ART/method-$ACTIVE_METHOD-qdisc-after.txt" 2>&1 || failed=1
      cmp -s "$ORIGINAL_QDISC_FILE" "$ART/method-$ACTIVE_METHOD-qdisc-after.txt" || failed=1 ;;
  esac
  printf '%s\tremove_mutation\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$ACTIVE_METHOD" "$MUTATION" "$AP" "$identifier" "$([ "$failed" = 0 ] && echo VERIFIED || echo FAILED)" >>"$LEDGER"
  [ "$failed" = 0 ] && MUTATION=
  return "$failed"
}

cleanup_trial() {
  [ -n "$AP" ] && docker unpause "$AP" >/dev/null 2>&1
  [ -n "$AP" ] && docker kill --signal CONT "$AP" >/dev/null 2>&1
  local cleanup_failed=0
  if [ -n "$AP" ] && docker inspect "$AP" >/dev/null 2>&1; then
    [ "$(docker inspect -f '{{.State.Paused}}' "$AP")" = false ] || cleanup_failed=1
    docker top "$AP" -eo stat 2>/dev/null | tail -n +2 | grep -q '^T' && cleanup_failed=1
  fi
  remove_mutation || cleanup_failed=1
  # Stop both disposable probe services after communication is restored.
  # The next trial restarts these same containers in place because legacy
  # Compose cannot reliably recreate them against current Docker metadata.
  [ -n "$NETADMIN" ] && docker stop --time 3 "$NETADMIN" >>"$ART/netadmin-stop.log" 2>&1 || true
  [ -n "$AP" ] && docker stop --time 3 "$AP" >>"$ART/ap-stop.log" 2>&1 || true
  sleep 1
  if [ -n "$BEFORE_FILE" ] && [ -s "$BEFORE_FILE" ] && [ -n "$DB" ]; then
    python3 - "$BEFORE_FILE" <<'PY' >"$ART/pids-to-clean.txt"
import json,sys
d=json.load(open(sys.argv[1]))
for r in d['pg_rows']:
 print('|'.join(map(str,(r['pid'],r['backend_start'],r['client_addr'],r['client_port']))))
PY
    while IFS='|' read -r pid backend_start client_addr client_port; do
      # Every predicate is from the before ledger; a reused PID cannot match.
      terminate_result=$(docker exec "$DB" psql -U probe -d probe -At \
        -v pid="$pid" -v started="$backend_start" -v addr="$client_addr" -v port="$client_port" \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE pid=:pid AND application_name='ap-server-1' AND backend_start=:'started'::timestamptz AND client_addr=:'addr'::inet AND client_port=:port;" 2>>"$ART/terminate.log") || cleanup_failed=1
      printf '%s|%s\n' "$pid" "$terminate_result" >>"$ART/terminate.log"
      [ "$terminate_result" != f ] || cleanup_failed=1
    done <"$ART/pids-to-clean.txt"
  fi
  sleep 1
  return "$cleanup_failed"
}

restart_trial_services() {
  local log=$1
  {
    docker unpause "$AP" >/dev/null 2>&1 || true
    docker kill --signal CONT "$AP" >/dev/null 2>&1 || true
    docker stop --time 3 "$NETADMIN" >/dev/null 2>&1 || true
    docker stop --time 3 "$AP" >/dev/null 2>&1 || true
    docker start "$AP"
    docker start "$NETADMIN"
    [ "$(docker inspect -f '{{.State.Running}}' "$AP")" = true ]
    [ "$(docker inspect -f '{{.State.Running}}' "$NETADMIN")" = true ]
  } >"$log" 2>&1
}

wait_for_probe_connections() {
  local out=$1 deadline=$((SECONDS + 30)) matched=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$AP" 2>/dev/null)" = true ] && \
       bash scripts/check-connections.sh readiness "$out" >/dev/null 2>&1; then
      matched=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("matched_count",0))' "$out" 2>/dev/null || echo 0)
      [ "$matched" -ge 3 ] && return 0
    fi
    sleep 1
  done
  return 1
}

cleanup_all() {
  [ "$CLEANED" = 1 ] && return; CLEANED=1
  rollback_config || true
  cleanup_trial || true
  [ "$COMPOSE_KIND" != unavailable ] && compose -p "$PROJECT" -f phase0/docker-compose.yml down -v --remove-orphans >>"$ART/compose-down.log" 2>&1 || true
}
on_signal() {
  local rc=$1
  ABORTED=1
  trap - INT TERM
  cleanup_all
  fail_exit "terminated by signal (rc=$rc)" "$rc" "$RESULT"
}
trap cleanup_all EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

TEST_STARTED=1
command -v flock >/dev/null || fail_exit 'flock is required for selected config serialization' 127 "$RESULT"
flock --version >"$ART/flock-version.txt" 2>&1 || fail_exit 'flock capability probe failed' 1 "$ART/flock-version.txt"
if ! exec 9>config/.selected-method.lock; then
  fail_exit 'failed to open selected config lock' 1 'config/.selected-method.lock'
fi
flock -n 9 || fail_exit 'another selected config writer holds the lock' 75 'config/.selected-method.lock'
required_event flock_probe PASS 0 '{"reason":"run-independent selected config lock acquired on fd 9"}'
if [ -f "$CONFIG_TARGET" ]; then
  existing_env=$(python3 -c 'import json; print(json.load(open("config/selected-method.json"))["environment_id"])' 2>/dev/null || echo INVALID)
  [ "$existing_env" = "$ENV_ID" ] || fail_exit "existing selection environment mismatch: $existing_env" 2 "$CONFIG_TARGET"
fi
command -v docker >/dev/null || fail_exit 'docker missing' 127 "$RESULT"
docker info >"$ART/docker-info.txt" 2>&1 || fail_exit 'docker daemon unavailable' 1 "$ART/docker-info.txt"
[ "$COMPOSE_KIND" != unavailable ] || fail_exit 'Docker Compose plugin and standalone docker-compose unavailable' 1 "$ART/compose-version.txt"
required_event capability PASS 0 '{"reason":"docker and compose executable"}'
progress 'base Docker/Compose capability PASS'

# L6: separate, real starts; neither result is inferred from the other.
if docker run --rm --privileged alpine:3.20 sh -c 'test -r /proc/1/status' >"$ART/privileged.txt" 2>&1; then required_event privileged_probe PASS 0 '{"reason":"isolated privileged container started"}'; else required_event privileged_probe FAIL $? '{"reason":"privileged container rejected"}'; fi
if docker run --rm --cap-add NET_ADMIN alpine:3.20 sh -c "grep -q '^CapEff:' /proc/self/status" >"$ART/net-admin.txt" 2>&1; then required_event net_admin_probe PASS 0 '{"reason":"isolated NET_ADMIN container started"}'; else required_event net_admin_probe FAIL $? '{"reason":"NET_ADMIN container rejected"}'; fi

progress 'building isolated probe stack'
compose -p "$PROJECT" -f phase0/docker-compose.yml up -d --build >"$ART/compose-up.txt" 2>&1 || fail_exit 'probe stack failed' 1 "$ART/compose-up.txt"
DB=$(compose -p "$PROJECT" -f phase0/docker-compose.yml ps -q db)
AP=$(compose -p "$PROJECT" -f phase0/docker-compose.yml ps -q ap)
NETADMIN=$(compose -p "$PROJECT" -f phase0/docker-compose.yml ps -q netadmin)
DB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DB")
TAG="p0_${SAFE_ID//-/_}"; TAG=${TAG:0:24}
docker pause "$AP" >"$ART/pause.txt" 2>&1 && docker unpause "$AP" >>"$ART/pause.txt" 2>&1 && required_event pause_probe PASS 0 '{"reason":"pause/unpause executed"}' || required_event pause_probe FAIL $? '{"reason":"pause/unpause failed"}'
docker kill --signal STOP "$AP" >"$ART/signal.txt" 2>&1 && docker kill --signal CONT "$AP" >>"$ART/signal.txt" 2>&1 && required_event signal_probe PASS 0 '{"reason":"SIGSTOP/SIGCONT executed"}' || required_event signal_probe FAIL $? '{"reason":"signal failed"}'
docker exec "$DB" ss -Hnt >"$ART/ss-probe.txt" 2>&1 && required_event ss_probe PASS 0 '{"reason":"DB namespace ss executed"}' || required_event ss_probe FAIL $? '{}'
docker exec "$DB" psql -U probe -d probe -c 'select count(*) from pg_stat_activity' >"$ART/pg-probe.txt" 2>&1 && required_event postgres_probe PASS 0 '{"reason":"pg_stat_activity readable"}' || fail_exit 'pg_stat_activity probe failed' 1 "$ART/pg-probe.txt"

# Capability probes mutate only a uniquely named chain/table or disposable dummy link.
if docker exec "$NETADMIN" iptables -N "$TAG" && docker exec "$NETADMIN" iptables -X "$TAG"; then required_event iptables_probe PASS 0 '{"reason":"unique chain add/delete executed"}'; else docker exec "$NETADMIN" iptables -F "$TAG" >/dev/null 2>&1 || true; docker exec "$NETADMIN" iptables -X "$TAG" >/dev/null 2>&1 || true; required_event iptables_probe FAIL 1 '{}'; fi
if docker exec "$NETADMIN" nft add table inet "$TAG" && docker exec "$NETADMIN" nft delete table inet "$TAG"; then required_event nft_probe PASS 0 '{"reason":"unique table add/delete executed"}'; else docker exec "$NETADMIN" nft delete table inet "$TAG" >/dev/null 2>&1 || true; required_event nft_probe FAIL 1 '{}'; fi
if docker exec "$NETADMIN" ip link add p0dummy type dummy && docker exec "$NETADMIN" tc qdisc add dev p0dummy root netem loss 100% && docker exec "$NETADMIN" tc qdisc del dev p0dummy root && docker exec "$NETADMIN" ip link del p0dummy; then required_event netns_tc_probe PASS 0 '{"reason":"dummy link and netem add/delete executed"}'; else docker exec "$NETADMIN" tc qdisc del dev p0dummy root >/dev/null 2>&1 || true; docker exec "$NETADMIN" ip link del p0dummy >/dev/null 2>&1 || true; required_event netns_tc_probe FAIL 1 '{}'; fi
docker exec "$NETADMIN" nsenter --net=/proc/1/ns/net ip link show >"$ART/nsenter.txt" 2>&1 && required_event nsenter_probe PASS 0 '{"reason":"network namespace entered"}' || required_event nsenter_probe FAIL $? '{}'
docker exec "$NETADMIN" conntrack -L >"$ART/conntrack.txt" 2>&1 && required_event conntrack_probe PASS 0 '{"reason":"conntrack readable"}' || required_event conntrack_probe UNKNOWN $? '{"reason":"conntrack is supplemental"}'

inject() {
  local method=$1
  [ "$ABORTED" = 0 ] || return 125
  case "$method" in
    A|B|C)
      if docker exec "$NETADMIN" iptables -I OUTPUT 1 -p tcp -d "$DB_IP" --dport 5432 -m comment --comment "$TAG" -j DROP; then
        MUTATION=iptables
        printf '%s\tadd_mutation\t%s\tiptables\t%s\t%s\tRECORDED\n' "$(date -u +%FT%TZ)" "$ACTIVE_METHOD" "$AP" "$TAG" >>"$LEDGER"
        docker exec "$NETADMIN" iptables -I INPUT 1 -p tcp -s "$DB_IP" --sport 5432 -m comment --comment "$TAG" -j DROP || { remove_mutation; return 1; }
      elif docker exec "$NETADMIN" nft add table inet "$TAG"; then
        MUTATION=nft
        printf '%s\tadd_mutation\t%s\tnft\t%s\t%s\tRECORDED\n' "$(date -u +%FT%TZ)" "$ACTIVE_METHOD" "$AP" "$TAG" >>"$LEDGER"
        docker exec "$NETADMIN" nft "add chain inet $TAG output { type filter hook output priority 0; policy accept; }" && \
        docker exec "$NETADMIN" nft "add chain inet $TAG input { type filter hook input priority 0; policy accept; }" && \
        docker exec "$NETADMIN" nft add rule inet "$TAG" output ip daddr "$DB_IP" tcp dport 5432 drop && \
        docker exec "$NETADMIN" nft add rule inet "$TAG" input ip saddr "$DB_IP" tcp sport 5432 drop || { remove_mutation; return 1; }
      else return 1; fi
      case "$method" in A) docker pause "$AP";; B) docker kill --signal STOP "$AP";; C) docker kill --signal KILL "$AP";; esac ;;
    D)
      ORIGINAL_LINK_FILE="$ART/method-$ACTIVE_METHOD-link-before.txt"
      docker exec "$NETADMIN" cat /sys/class/net/eth0/operstate >"$ORIGINAL_LINK_FILE" || return 1
      grep -qx up "$ORIGINAL_LINK_FILE" || return 1
      docker exec "$NETADMIN" ip link set eth0 down && MUTATION=link && printf '%s\tadd_mutation\t%s\tlink\t%s\t%s\tRECORDED\n' "$(date -u +%FT%TZ)" "$ACTIVE_METHOD" "$AP" "$ORIGINAL_LINK_FILE" >>"$LEDGER" && docker pause "$AP" ;;
    E)
      ORIGINAL_QDISC_FILE="$ART/method-$ACTIVE_METHOD-qdisc-before.txt"
      docker exec "$NETADMIN" tc qdisc show dev eth0 >"$ORIGINAL_QDISC_FILE" || return 1
      grep -q netem "$ORIGINAL_QDISC_FILE" && return 1
      grep -q '^qdisc noqueue .* root' "$ORIGINAL_QDISC_FILE" || return 1
      docker exec "$NETADMIN" tc qdisc add dev eth0 root netem loss 100% && MUTATION=tc && printf '%s\tadd_mutation\t%s\ttc\t%s\t%s\tRECORDED\n' "$(date -u +%FT%TZ)" "$ACTIVE_METHOD" "$AP" "$ORIGINAL_QDISC_FILE" >>"$LEDGER" && docker pause "$AP" ;;
  esac
}

trial() {
  local method=$1 expected point file state before_pm after_pm matched ok=1
  [ "$ABORTED" = 0 ] || return 125
  ACTIVE_METHOD=$method; MUTATION=; BEFORE_FILE="$ART/method-$method-before.json"; ORIGINAL_LINK_FILE=; ORIGINAL_QDISC_FILE=
  # Restart the existing AP probe containers between trials; PostgreSQL is
  # never restarted. Do not use Compose v1 --force-recreate: it raises
  # KeyError: ContainerConfig with current Docker engines.
  progress "trying method $method"
  if ! restart_trial_services "$ART/method-$method-start.log"; then
    required_event method_trial FAIL 1 "{\"method\":\"$method\",\"method_state\":\"TRIAL_FAILED\",\"reason\":\"probe AP/netadmin in-place restart failed\",\"artifact_path\":\"$ART/method-$method-start.log\"}"
    cleanup_trial
    return 1
  fi
  if ! wait_for_probe_connections "$ART/method-$method-readiness.json"; then
    required_event method_trial FAIL 1 "{\"method\":\"$method\",\"method_state\":\"TRIAL_FAILED\",\"reason\":\"three correlated probe connections were not ready within 30 seconds\",\"artifact_path\":\"$ART/method-$method-readiness.json\"}"
    cleanup_trial
    return 1
  fi
  record_before_state "$method" || { required_event method_trial FAIL 1 "{\"method\":\"$method\",\"method_state\":\"TRIAL_FAILED\",\"reason\":\"before AP state is not externally proven RUNNING\",\"artifact_path\":\"$ART/method-$method-before-inspect.json\"}"; return 1; }
  bash scripts/check-connections.sh before "$BEFORE_FILE" || { required_event method_trial FAIL 1 "{\"method\":\"$method\",\"method_state\":\"TRIAL_FAILED\",\"reason\":\"before observation failed\"}"; return 1; }
  required_event observation PASS 0 "$(python3 - "$BEFORE_FILE" "$method" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); d.update(method=sys.argv[2],method_state='CAPABLE',reason='before observed',ap_stop_state='RUNNING',ap_stop_state_expected='RUNNING',ap_stop_state_source='docker host inspection',artifact_path=sys.argv[1]); print(json.dumps(d,separators=(',',':')))
PY
)"
  matched=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["matched_count"])' "$BEFORE_FILE")
  [ "$matched" -ge 2 ] || { required_event method_trial FAIL 1 "{\"method\":\"$method\",\"method_state\":\"TRIAL_FAILED\",\"reason\":\"fewer than two matched connections\"}"; return 1; }
  before_pm=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pg_postmaster_start_time"])' "$BEFORE_FILE")
  expected=$([ "$method" = B ] && echo STOPPED || { [ "$method" = C ] && echo EXITED/ABSENT || echo PAUSED; })
  if ! inject "$method" >"$ART/method-$method-inject.log" 2>&1; then required_event method_trial FAIL 1 "{\"method\":\"$method\",\"method_state\":\"CAPABILITY_FAILED\",\"reason\":\"injection rejected\"}"; cleanup_trial; return 1; fi
  for spec in immediate_after:0 after_5s:5 after_15s:10; do
    point=${spec%:*}; sleep "${spec#*:}"; file="$ART/method-$method-$point.json"
    bash scripts/check-connections.sh "$point" "$file" || ok=0
    state=$(stop_state "$method"); matched=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("matched_count",0))' "$file" 2>/dev/null || echo 0)
    # Count only before PIDs whose backend_start and canonical tuple are unchanged.
    matched=$(python3 - "$BEFORE_FILE" "$file" <<'PY'
import json,sys
b,a=map(lambda p:json.load(open(p)),sys.argv[1:])
br={r['pid']:r for r in b['pg_rows']}; ar={r['pid']:r for r in a['pg_rows']}
bt={tuple(t) for t in b['matched_tuples']}; at={tuple(t) for t in a['matched_tuples']}
n=0
for pid,r in br.items():
 q=ar.get(pid)
 if q and q['backend_start']==r['backend_start'] and q['client_addr']==r['client_addr'] and q['client_port']==r['client_port']:
  if any(t[2]==r['client_addr'] and t[3]==r['client_port'] for t in bt & at): n+=1
print(n)
PY
    )
    [ "$state" = "$expected" ] && [ "$matched" -ge 2 ] || ok=0
    payload=$(python3 - "$file" "$method" "$point" "$state" "$expected" "$matched" <<'PY'
import json,sys
p,method,point,state,expected,matched=sys.argv[1:]
d=json.load(open(p)); d.update(method=method,method_state='CAPABLE',point=point,reason='observed',ap_stop_state=state,ap_stop_state_expected=expected,ap_stop_state_source='docker host inspection',matched_count=int(matched),artifact_path=p)
print(json.dumps(d,separators=(',',':')))
PY
    )
    required_event observation $([ "$ok" = 1 ] && echo PASS || echo FAIL) "$((1-ok))" "$payload"
    progress "method=$method point=$point state=$state matched=$matched"
  done
  after_pm=$(docker exec "$DB" psql -U probe -d probe -At -c 'select pg_postmaster_start_time()' 2>/dev/null || echo unavailable)
  [ "$before_pm" = "$after_pm" ] || ok=0
  cleanup_trial || ok=0
  docker exec "$DB" pg_isready -U probe -d probe >/dev/null 2>&1 || ok=0
  [ -z "$MUTATION" ] || ok=0
  cleanup_file="$ART/method-$method-cleanup.json"
  bash scripts/check-connections.sh cleanup "$cleanup_file" || ok=0
  remaining=$(python3 - "$BEFORE_FILE" "$cleanup_file" <<'PY'
import json,sys
b,a=map(lambda p:json.load(open(p)),sys.argv[1:])
print(len(set(b['pg_backend_pids']) & set(a['pg_backend_pids'])) + len({tuple(x) for x in b['matched_tuples']} & {tuple(x) for x in a['canonical_tuples']}))
PY
  )
  [ "$remaining" = 0 ] || ok=0
  cleanup_pm=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pg_postmaster_start_time"])' "$cleanup_file")
  before_restart=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["db_restart_count"])' "$BEFORE_FILE")
  cleanup_restart=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["db_restart_count"])' "$cleanup_file")
  [ "$cleanup_pm" = "$before_pm" ] && [ "$cleanup_restart" = "$before_restart" ] || ok=0
  if [ "$ok" = 1 ]; then
    SELECTED_METHOD=$method; SELECTED_MATCHED=$matched; SELECTED_PM=$before_pm
    required_event method_qualified PASS 0 "{\"method\":\"$method\",\"method_state\":\"QUALIFIED\",\"reason\":\"15s PID/tuple persistence and cleanup verified\",\"point\":\"after_15s\",\"ap_stop_state\":\"$expected\",\"ap_stop_state_expected\":\"$expected\",\"ap_stop_state_source\":\"docker host inspection\",\"matched_count\":$matched,\"pg_postmaster_start_time\":\"$before_pm\",\"cleanup_verified\":true,\"artifact_path\":\"$cleanup_file\"}"
    return 0
  fi
  required_event method_trial FAIL 1 "{\"method\":\"$method\",\"method_state\":\"TRIAL_FAILED\",\"reason\":\"minimum line or cleanup failed\"}"
  return 1
}

SELECTED_METHOD=
for method in A B C D E; do trial "$method" && break; done
if [ -z "$SELECTED_METHOD" ]; then echo "Phase 0 FAIL: UNSELECTED (evidence: $RESULT)" | tee "$ART/summary.txt"; fail_exit 'all methods unselected' 1 "$RESULT"; fi
if [ "$ENVIRONMENT" != killercoda ]; then
  echo 'TEST-00 NOT_QUALIFIED: run in Killercoda' | tee "$ART/summary.txt"
  fail_exit 'NOT_QUALIFIED: evidence is not from Killercoda' 1 "$RESULT"
fi
if ! bash tests/test-00.sh "$RESULT" "$LEDGER" | tee "$ART/summary.txt"; then
  fail_exit 'independent TEST-00 validation failed' 1 "$RESULT"
fi
tmp="config/.selected-method.json.$$"
python3 - "$tmp" "$ENV_ID" "$RUN_ID" "$SELECTED_METHOD" "$ATTEMPT" "$RESULT" "$SELECTED_MATCHED" "$SELECTED_PM" <<'PY' || fail_exit 'failed to generate selected-method config' 70 "$tmp"
import datetime,json
import sys
p,environment_id,run_id,method,attempt,evidence,matched,postmaster=sys.argv[1:]
data={'schema_version':1,'environment':'killercoda','environment_id':environment_id,'run_id':run_id,'method':method,'selected_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'test_id':'TEST-00','attempt':int(attempt),'evidence_artifact':evidence,'matched_count':int(matched),'pg_postmaster_start_time':postmaster}
with open(p,'w',encoding='utf-8') as f: json.dump(data,f,indent=2); f.write('\n')
PY
arm_config_rollback || fail_exit 'failed to atomically back up existing selected-method config' 70 "$BACKUP_META"
if ! mv -n "$tmp" "$CONFIG_TARGET"; then
  fail_exit 'failed to commit selected-method config' 70 "$tmp"
fi
if [ -e "$tmp" ]; then
  fail_exit 'concurrent selected-method update detected; commit refused' 70 "$tmp"
fi
python3 - "$CONFIG_TARGET" "$RESULT" "$ATTEMPT" "$RUN_ID" <<'PY' || fail_exit 'selected-method evidence path validation failed' 70 "$CONFIG_TARGET"
import json,os,sys
p,evidence,attempt,run_id=sys.argv[1:]
d=json.load(open(p,encoding='utf-8'))
assert d['evidence_artifact']==evidence and d['attempt']==int(attempt) and d['run_id']==run_id
assert os.path.isfile(evidence)
PY
required_event method_selected PASS 0 "{\"reason\":\"independent TEST-00 passed\",\"method\":\"$SELECTED_METHOD\",\"method_state\":\"SELECTED\",\"cleanup_verified\":true,\"matched_count\":$SELECTED_MATCHED,\"pg_postmaster_start_time\":\"$SELECTED_PM\"}"
required_event test_result PASS 0 "{\"reason\":\"TEST-00 passed\",\"method\":\"$SELECTED_METHOD\"}"
record_success || fail_exit 'failed to reset TEST-00 failure counter' 70 "$FAIL_COUNT_FILE"
finalize_config_commit || fail_exit 'failed to remove verified config backup' 70 "$CONFIG_BACKUP"
progress "TEST-00 PASS method=$SELECTED_METHOD evidence=$RESULT"
