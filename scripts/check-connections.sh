#!/usr/bin/env bash
set -uo pipefail

PROJECT=${PHASE0_PROJECT:?PHASE0_PROJECT is required}
POINT=${1:-snapshot}
OUT=${2:-/dev/stdout}
compose() {
  case ${PHASE0_COMPOSE_KIND:-} in
    plugin) docker compose "$@" ;;
    standalone) docker-compose "$@" ;;
    *) echo 'PHASE0_COMPOSE_KIND must be plugin or standalone' >&2; return 2 ;;
  esac
}
DB=$(compose -p "$PROJECT" -f phase0/docker-compose.yml ps -q db)
AP=$(compose -p "$PROJECT" -f phase0/docker-compose.yml ps -q ap)
[ -n "$DB" ] && [ -n "$AP" ] || { echo 'probe stack is not running' >&2; exit 2; }

pg=$(docker exec "$DB" psql -U probe -d probe -At -F '|' -c \
  "SELECT pid,client_addr,client_port,backend_start,state FROM pg_stat_activity WHERE application_name='ap-server-1' ORDER BY pid") || exit 3
ss=$(docker exec "$DB" ss -Hnt state established '( sport = :5432 )') || exit 4
postmaster=$(docker exec "$DB" psql -U probe -d probe -At -c 'SELECT pg_postmaster_start_time()') || exit 5
restart_count=$(docker inspect -f '{{.RestartCount}}' "$DB") || exit 6

python3 - "$POINT" "$postmaster" "$restart_count" "$OUT" "$pg" "$ss" <<'PY'
import datetime, ipaddress, json, re, sys
point, postmaster, restart_count, out, pg_raw, ss_raw = sys.argv[1:]
def addr(value):
    value=value.strip('[]').split('%')[0]
    if value.lower().startswith('::ffff:'): value=value[7:]
    return str(ipaddress.ip_address(value)).lower()
pg=[]
for line in pg_raw.splitlines():
    if not line: continue
    pid,client,cport,start,state=line.split('|',4)
    pg.append({'pid':int(pid),'client_addr':addr(client),'client_port':int(cport),'backend_start':start,'state':state})
ssrows=[]
for line in ss_raw.splitlines():
    cols=line.split()
    if len(cols)<4: continue
    local,peer=cols[-2:]
    def endpoint(s):
        m=re.match(r'^\[?(.+?)\]?:([0-9]+)$',s)
        return (addr(m.group(1)),int(m.group(2))) if m else None
    le,pe=endpoint(local),endpoint(peer)
    if le and pe and le[1]==5432:
        ssrows.append({'tuple':[le[0],le[1],pe[0],pe[1]],'state':'ESTAB'})
tuples={tuple(x['tuple']) for x in ssrows}
matched=[x for x in pg if (next(iter({t[0] for t in tuples}),''),5432,x['client_addr'],x['client_port']) in tuples]
# DB address can differ by display family; endpoint equality on client tuple is authoritative in DB namespace.
matched=[]
for x in pg:
    hits=[t for t in tuples if t[1]==5432 and t[2]==x['client_addr'] and t[3]==x['client_port']]
    if len(hits)==1: matched.append(x)
obj={'ts':datetime.datetime.now(datetime.timezone.utc).isoformat(),'point':point,
     'pg_backend_pids':[x['pid'] for x in pg], 'pg_rows':pg,
     'canonical_tuples':[list(t) for t in sorted(tuples)],
     'matched_pids':[x['pid'] for x in matched],
     'matched_tuples':[list(t) for t in sorted(tuples) if any(t[2]==x['client_addr'] and t[3]==x['client_port'] for x in matched)],
     'matched_count':len(matched),'pg_postmaster_start_time':postmaster,
     'db_restart_count':int(restart_count)}
data=json.dumps(obj,separators=(',',':'))
if out=='/dev/stdout': print(data)
else:
    with open(out,'w',encoding='utf-8') as f: f.write(data+'\n')
PY
