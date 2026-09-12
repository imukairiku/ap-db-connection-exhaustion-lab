import json,os,threading
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
import psycopg2

AP=os.environ['AP_NAME']; DSN=dict(host=os.environ['DB_HOST'],user='app_user',password='app-only',dbname='lab',application_name=AP)
lock=threading.Lock(); gate=threading.Event(); requests={}
def emit(rid,event,**extra): print(json.dumps({'request_id':rid,'ap':AP,'event':event,**extra}),flush=True)
def worker(rid):
 conn=None
 phase='connect'
 try:
  emit(rid,'START'); conn=psycopg2.connect(connect_timeout=3,**DSN); phase='business'; cur=conn.cursor(); cur.execute('INSERT INTO business_results(request_id,ap_name) VALUES(%s,%s)',(rid,AP))
  with lock: requests[rid].update(connected=True,state='DB_CONNECTED')
  emit(rid,'DB_CONNECTED'); gate.wait(120)
 except Exception as error:
  with lock: requests[rid].update(active=False,state='CONNECTION_FAILED',error_type=type(error).__name__,error_phase=phase)
  emit(rid,'CONNECTION_FAILED',error_type=type(error).__name__,error_phase=phase,db_error=str(error).strip())
 finally:
  if conn:
   gate.wait(120); conn.close()
def state():
 with lock:
  rows=list(requests.values()); return {'accepted':len(rows),'active':sum(x['active'] for x in rows),'connected':sum(x['connected'] for x in rows),'failed':sum(x['state']=='CONNECTION_FAILED' for x in rows),'requests':rows}
class Handler(BaseHTTPRequestHandler):
 def reply(self,code,obj):
  body=json.dumps(obj).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
 def do_GET(self):
  if self.path=='/health': return self.reply(200,{'ready':True,'ap':AP})
  if self.path=='/state': return self.reply(200,state())
  self.reply(404,{'code':'not_found'})
 def do_POST(self):
  if self.path!='/batch': return self.reply(404,{'code':'not_found'})
  try:
   ids=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))['request_ids']
   if not 1<=len(ids)<=12 or len(ids)!=len(set(ids)): raise ValueError
  except (KeyError,ValueError,json.JSONDecodeError): return self.reply(400,{'code':'invalid_batch'})
  with lock:
   if requests: return self.reply(409,{'code':'batch_started'})
   for rid in ids: requests[rid]={'request_id':rid,'active':True,'connected':False,'state':'STARTING'}
  for rid in ids: threading.Thread(target=worker,args=(rid,),daemon=True).start()
  self.reply(202,{'request_ids':ids})
 def log_message(self,*_): pass
ThreadingHTTPServer(('0.0.0.0',8080),Handler).serve_forever()
