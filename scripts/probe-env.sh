#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
detect_environment() {
  if [ -f /etc/killercoda ] || [ -d /root/.killercoda ] || [ -n "${KILLERCODA:-}" ] || hostname | grep -qi killercoda; then
    echo killercoda
  else
    echo local
  fi
}
DETECTED_ENVIRONMENT=$(detect_environment)
ENVIRONMENT=${PHASE0_ENVIRONMENT:-$DETECTED_ENVIRONMENT}
ENV_ID=${PHASE0_ENVIRONMENT_ID:-$(hostname)-$(date -u +%Y%m%dT%H%M%SZ)-$$}
SAFE_ID=$(printf '%s' "$ENV_ID" | tr -cd 'a-zA-Z0-9_.-')
PROJECT="phase0-${SAFE_ID,,}"
PROJECT=${PROJECT:0:55}
ART="artifacts/phase0/$SAFE_ID"
RESULT="$ART/result.jsonl"
LEDGER="$ART/cleanup-ledger.tsv"
mkdir -p "$ART" config
: >"$RESULT"; : >"$LEDGER"
export PHASE0_PROJECT="$PROJECT"
HOST=$(hostname); KERNEL=$(uname -sr)
DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unavailable)
COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo unavailable)
ATTEMPT=${PHASE0_ATTEMPT:-1}; SEQ=0; CLEANED=0; ABORTED=0
DB= AP= NETADMIN= DB_IP= TAG=; ACTIVE_METHOD=; BEFORE_FILE=; RULE_KIND=; MUTATION=
ORIGINAL_LINK_FILE= ORIGINAL_QDISC_FILE=

if [ "$ENVIRONMENT" != "$DETECTED_ENVIRONMENT" ]; then
  echo "PHASE0_ENVIRONMENT override disagrees with detected environment ($DETECTED_ENVIRONMENT)" >&2
  exit 2
fi

if [ -f config/selected-method.json ]; then
  existing_env=$(python3 -c 'import json; print(json.load(open("config/selected-method.json"))["environment_id"])' 2>/dev/null || echo INVALID)
  if [ "$existing_env" != "$ENV_ID" ]; then
    echo "Existing selection belongs to a different environment_id: $existing_env" >&2
    exit 2
  fi
fi

json_event() {
  local event=$1 status=$2 rc=$3 extra=${4:-{}}
  SEQ=$((SEQ+1))
  python3 - "$RESULT" "$event" "$status" "$rc" "$extra" "$SEQ" <<PY
import datetime,json,sys
p,event,status,rc,extra,seq=sys.argv[1:]
base=dict(ts=datetime.datetime.now(datetime.timezone.utc).isoformat(),phase='Phase 0',test_id='TEST-00',event=event,status=status,rc=int(rc),environment=${ENVIRONMENT@Q},environment_id=${ENV_ID@Q},hostname=${HOST@Q},kernel=${KERNEL@Q},docker_version=${DOCKER_VERSION@Q},compose_version=${COMPOSE_VERSION@Q},attempt=int(${ATTEMPT}),command_id=f'cmd-{seq}',artifact_path=${ART@Q})
try: base.update(json.loads(extra))
except Exception as e: base.update(reason='invalid event payload: '+str(e))
with open(p,'a',encoding='utf-8') as f: f.write(json.dumps(base,separators=(',',':'))+'\n')
PY
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
  # Once communication is restored, stop the disposable AP normally first.
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

cleanup_all() {
  [ "$CLEANED" = 1 ] && return; CLEANED=1
  cleanup_trial || true
  docker compose -p "$PROJECT" -f phase0/docker-compose.yml down -v --remove-orphans >>"$ART/compose-down.log" 2>&1 || true
}
on_signal() {
  local rc=$1
  ABORTED=1
  trap - INT TERM
  cleanup_all
  exit "$rc"
}
trap cleanup_all EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

command -v docker >/dev/null || { json_event capability FAIL 127 '{"reason":"docker missing"}'; exit 1; }
docker info >"$ART/docker-info.txt" 2>&1 || { json_event capability FAIL 1 '{"reason":"docker daemon unavailable"}'; exit 1; }
docker compose version >"$ART/compose-version.txt" 2>&1 || { json_event capability FAIL 1 '{"reason":"compose unavailable"}'; exit 1; }
json_event capability PASS 0 '{"reason":"docker and compose executable"}'

# L6: separate, real starts; neither result is inferred from the other.
if docker run --rm --privileged alpine:3.20 sh -c 'test -r /proc/1/status' >"$ART/privileged.txt" 2>&1; then json_event privileged_probe PASS 0 '{"reason":"isolated privileged container started"}'; else json_event privileged_probe FAIL $? '{"reason":"privileged container rejected"}'; fi
if docker run --rm --cap-add NET_ADMIN alpine:3.20 sh -c "grep -q '^CapEff:' /proc/self/status" >"$ART/net-admin.txt" 2>&1; then json_event net_admin_probe PASS 0 '{"reason":"isolated NET_ADMIN container started"}'; else json_event net_admin_probe FAIL $? '{"reason":"NET_ADMIN container rejected"}'; fi

docker compose -p "$PROJECT" -f phase0/docker-compose.yml up -d --build >"$ART/compose-up.txt" 2>&1 || { json_event stack FAIL 1 '{"reason":"probe stack failed"}'; exit 1; }
DB=$(docker compose -p "$PROJECT" -f phase0/docker-compose.yml ps -q db)
AP=$(docker compose -p "$PROJECT" -f phase0/docker-compose.yml ps -q ap)
NETADMIN=$(docker compose -p "$PROJECT" -f phase0/docker-compose.yml ps -q netadmin)
DB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$DB")
TAG="p0_${SAFE_ID//-/_}"; TAG=${TAG:0:24}
docker pause "$AP" >"$ART/pause.txt" 2>&1 && docker unpause "$AP" >>"$ART/pause.txt" 2>&1 && json_event pause_probe PASS 0 '{"reason":"pause/unpause executed"}' || json_event pause_probe FAIL $? '{"reason":"pause/unpause failed"}'
docker kill --signal STOP "$AP" >"$ART/signal.txt" 2>&1 && docker kill --signal CONT "$AP" >>"$ART/signal.txt" 2>&1 && json_event signal_probe PASS 0 '{"reason":"SIGSTOP/SIGCONT executed"}' || json_event signal_probe FAIL $? '{"reason":"signal failed"}'
docker exec "$DB" ss -Hnt >"$ART/ss-probe.txt" 2>&1 && json_event ss_probe PASS 0 '{"reason":"DB namespace ss executed"}' || json_event ss_probe FAIL $? '{}'
docker exec "$DB" psql -U probe -d probe -c 'select count(*) from pg_stat_activity' >"$ART/pg-probe.txt" 2>&1 && json_event postgres_probe PASS 0 '{"reason":"pg_stat_activity readable"}' || { json_event postgres_probe FAIL $? '{}'; exit 1; }

# Capability probes mutate only a uniquely named chain/table or disposable dummy link.
if docker exec "$NETADMIN" iptables -N "$TAG" && docker exec "$NETADMIN" iptables -X "$TAG"; then json_event iptables_probe PASS 0 '{"reason":"unique chain add/delete executed"}'; else docker exec "$NETADMIN" iptables -F "$TAG" >/dev/null 2>&1 || true; docker exec "$NETADMIN" iptables -X "$TAG" >/dev/null 2>&1 || true; json_event iptables_probe FAIL 1 '{}'; fi
if docker exec "$NETADMIN" nft add table inet "$TAG" && docker exec "$NETADMIN" nft delete table inet "$TAG"; then json_event nft_probe PASS 0 '{"reason":"unique table add/delete executed"}'; else docker exec "$NETADMIN" nft delete table inet "$TAG" >/dev/null 2>&1 || true; json_event nft_probe FAIL 1 '{}'; fi
if docker exec "$NETADMIN" ip link add p0dummy type dummy && docker exec "$NETADMIN" tc qdisc add dev p0dummy root netem loss 100% && docker exec "$NETADMIN" tc qdisc del dev p0dummy root && docker exec "$NETADMIN" ip link del p0dummy; then json_event netns_tc_probe PASS 0 '{"reason":"dummy link and netem add/delete executed"}'; else docker exec "$NETADMIN" tc qdisc del dev p0dummy root >/dev/null 2>&1 || true; docker exec "$NETADMIN" ip link del p0dummy >/dev/null 2>&1 || true; json_event netns_tc_probe FAIL 1 '{}'; fi
docker exec "$NETADMIN" nsenter --net=/proc/1/ns/net ip link show >"$ART/nsenter.txt" 2>&1 && json_event nsenter_probe PASS 0 '{"reason":"network namespace entered"}' || json_event nsenter_probe FAIL $? '{}'
docker exec "$NETADMIN" conntrack -L >"$ART/conntrack.txt" 2>&1 && json_event conntrack_probe PASS 0 '{"reason":"conntrack readable"}' || json_event conntrack_probe UNKNOWN $? '{"reason":"conntrack is supplemental"}'

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
  # restart only the AP probe between independent trials; PostgreSQL is never restarted.
  docker compose -p "$PROJECT" -f phase0/docker-compose.yml up -d --no-deps --force-recreate ap netadmin >"$ART/method-$method-start.log" 2>&1 || return 1
  AP=$(docker compose -p "$PROJECT" -f phase0/docker-compose.yml ps -q ap); NETADMIN=$(docker compose -p "$PROJECT" -f phase0/docker-compose.yml ps -q netadmin)
  sleep 2
  record_before_state "$method" || { json_event method_trial FAIL 1 "{\"method\":\"$method\",\"method_state\":\"TRIAL_FAILED\",\"reason\":\"before AP state is not externally proven RUNNING\",\"artifact_path\":\"$ART/method-$method-before-inspect.json\"}"; return 1; }
  bash scripts/check-connections.sh before "$BEFORE_FILE" || { json_event method_trial FAIL 1 "{\"method\":\"$method\",\"method_state\":\"TRIAL_FAILED\",\"reason\":\"before observation failed\"}"; return 1; }
  json_event observation PASS 0 "$(python3 - "$BEFORE_FILE" "$method" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); d.update(method=sys.argv[2],method_state='CAPABLE',reason='before observed',ap_stop_state='RUNNING',ap_stop_state_expected='RUNNING',ap_stop_state_source='docker host inspection',artifact_path=sys.argv[1]); print(json.dumps(d,separators=(',',':')))
PY
)"
  matched=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["matched_count"])' "$BEFORE_FILE")
  [ "$matched" -ge 2 ] || { json_event method_trial FAIL 1 "{\"method\":\"$method\",\"method_state\":\"TRIAL_FAILED\",\"reason\":\"fewer than two matched connections\"}"; return 1; }
  before_pm=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pg_postmaster_start_time"])' "$BEFORE_FILE")
  expected=$([ "$method" = B ] && echo STOPPED || { [ "$method" = C ] && echo EXITED/ABSENT || echo PAUSED; })
  if ! inject "$method" >"$ART/method-$method-inject.log" 2>&1; then json_event method_trial FAIL 1 "{\"method\":\"$method\",\"method_state\":\"CAPABILITY_FAILED\",\"reason\":\"injection rejected\"}"; cleanup_trial; return 1; fi
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
    json_event observation $([ "$ok" = 1 ] && echo PASS || echo FAIL) "$((1-ok))" "$payload"
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
    json_event method_qualified PASS 0 "{\"method\":\"$method\",\"method_state\":\"QUALIFIED\",\"reason\":\"15s PID/tuple persistence and cleanup verified\",\"point\":\"after_15s\",\"ap_stop_state\":\"$expected\",\"ap_stop_state_expected\":\"$expected\",\"ap_stop_state_source\":\"docker host inspection\",\"matched_count\":$matched,\"pg_postmaster_start_time\":\"$before_pm\",\"cleanup_verified\":true,\"artifact_path\":\"$cleanup_file\"}"
    return 0
  fi
  json_event method_trial FAIL 1 "{\"method\":\"$method\",\"method_state\":\"TRIAL_FAILED\",\"reason\":\"minimum line or cleanup failed\"}"
  return 1
}

SELECTED_METHOD=
for method in A B C D E; do trial "$method" && break; done
if [ -z "$SELECTED_METHOD" ]; then echo 'Phase 0 FAIL: UNSELECTED' | tee "$ART/summary.txt"; json_event test_result FAIL 1 '{"reason":"all methods unselected"}'; exit 1; fi
if [ "$ENVIRONMENT" != killercoda ]; then
  json_event test_result FAIL 1 "{\"reason\":\"NOT_QUALIFIED: evidence is not from Killercoda\",\"method\":\"$SELECTED_METHOD\"}"
  echo 'TEST-00 NOT_QUALIFIED: run in Killercoda' | tee "$ART/summary.txt"
  exit 1
fi
if ! bash tests/test-00.sh "$RESULT" "$LEDGER" | tee "$ART/summary.txt"; then
  json_event test_result FAIL 1 '{"reason":"independent TEST-00 validation failed"}'
  exit 1
fi
tmp="config/.selected-method.json.$$"
python3 - "$tmp" <<PY
import datetime,json
json.dump({'schema_version':1,'environment':'killercoda','environment_id':${ENV_ID@Q},'method':${SELECTED_METHOD@Q},'selected_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'test_id':'TEST-00','attempt':int(${ATTEMPT}),'evidence_artifact':${RESULT@Q},'matched_count':int(${SELECTED_MATCHED}),'pg_postmaster_start_time':${SELECTED_PM@Q}},open(${tmp@Q},'w'),indent=2); open(${tmp@Q},'a').write('\n')
PY
mv "$tmp" config/selected-method.json
json_event method_selected PASS 0 "{\"reason\":\"independent TEST-00 passed\",\"method\":\"$SELECTED_METHOD\",\"method_state\":\"SELECTED\",\"cleanup_verified\":true,\"matched_count\":$SELECTED_MATCHED,\"pg_postmaster_start_time\":\"$SELECTED_PM\"}"
json_event test_result PASS 0 "{\"reason\":\"TEST-00 passed\",\"method\":\"$SELECTED_METHOD\"}"
