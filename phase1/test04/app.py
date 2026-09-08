import json, os, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import psycopg2

DSN=dict(host=os.environ['DB_HOST'],user=os.environ['DB_USER'],password=os.environ['DB_PASSWORD'],dbname=os.environ['DB_NAME'],application_name='ap-server-1')
lock=threading.Lock(); gate=threading.Event(); requests={}

def emit(rid,event): print(json.dumps({'request_id':rid,'ap':'ap-server-1','event':event}),flush=True)
def worker(rid):
 conn=None
 try:
  emit(rid,'START'); conn=psycopg2.connect(connect_timeout=5,**DSN); cur=conn.cursor(); cur.execute('SELECT 1')
  with lock: requests[rid].update(connected=True,waiting=True)
  emit(rid,'DB_CONNECTED'); gate.wait(120)
  with lock: requests[rid]['waiting']=False
  conn.commit(); emit(rid,'COMMIT'); emit(rid,'SUCCESS')
 except Exception:
  if conn:
   try: conn.rollback(); emit(rid,'ROLLBACK')
   except Exception: pass
  emit(rid,'FAILURE')
 finally:
  if conn: conn.close()
  with lock: requests[rid]['active']=False

class Handler(BaseHTTPRequestHandler):
 def reply(self,code,obj):
  body=json.dumps(obj).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
 def do_GET(self):
  if self.path=='/health': return self.reply(200,{'ready':True})
  if self.path=='/state':
   with lock:
    rows=list(requests.values()); return self.reply(200,{'active':sum(x['active'] for x in rows),'connected':sum(x['connected'] for x in rows),'waiting':sum(x['waiting'] for x in rows),'requests':rows})
  self.reply(404,{'code':'not_found'})
 def do_POST(self):
  if self.path!='/batch': return self.reply(404,{'code':'not_found'})
  try:
   data=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0')))); ids=data['request_ids']
   if len(ids)!=12 or len(set(ids))!=12 or any(not isinstance(x,str) or not x for x in ids): raise ValueError
  except (KeyError,ValueError,json.JSONDecodeError): return self.reply(400,{'code':'invalid_batch'})
  with lock:
   if requests: return self.reply(409,{'code':'batch_already_started'})
   for rid in ids: requests[rid]={'request_id':rid,'active':True,'connected':False,'waiting':False}
  for rid in ids: threading.Thread(target=worker,args=(rid,),daemon=True).start()
  self.reply(202,{'request_ids':ids})
 def log_message(self,*_): pass

ThreadingHTTPServer(('0.0.0.0',8080),Handler).serve_forever()
