import ipaddress,json,re,sys
pg_path,ss_path,out=sys.argv[1:]
def ip(value):
 value=value.strip('[]').split('%')[0]; value=value[7:] if value.lower().startswith('::ffff:') else value
 return str(ipaddress.ip_address(value)).lower()
pg=[]
for line in open(pg_path,encoding='utf-8'):
 if line.strip():
  pid,address,port,started,state=line.strip().split('|'); pg.append({'pid':int(pid),'client_addr':ip(address),'client_port':int(port),'backend_start':started,'state':state})
tuples=[]
for line in open(ss_path,encoding='utf-8'):
 parts=line.split()
 if len(parts)<4: continue
 def endpoint(value):
  match=re.match(r'^\[?(.+?)\]?:([0-9]+)$',value); return (ip(match.group(1)),int(match.group(2))) if match else None
 local,peer=endpoint(parts[-2]),endpoint(parts[-1])
 if local and peer and local[1]==5432: tuples.append({'db_addr':local[0],'db_port':local[1],'client_addr':peer[0],'client_port':peer[1]})
matched=[row['pid'] for row in pg if sum(t['client_addr']==row['client_addr'] and t['client_port']==row['client_port'] for t in tuples)==1]
json.dump({'pg_rows':pg,'tcp_tuples':tuples,'pg_count':len(pg),'ss_count':len(tuples),'matched_pids':matched,'matched_count':len(matched)},open(out,'w'),indent=2)
