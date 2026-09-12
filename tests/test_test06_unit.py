import json,py_compile,subprocess,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class Test06Preparation(unittest.TestCase):
 def test_python(self):
  for p in ('phase2/test06/app.py','phase2/test06/hold-admin.py','scripts/test06-counter.py','scripts/test06-validate.py'): py_compile.compile(ROOT/p,doraise=True)
 def test_real_capacity_scope(self):
  r=(ROOT/'tests/test-06.sh').read_text(); c=(ROOT/'tests/test-06.compose.yml').read_text(); self.assertIn("current_setting('max_connections')",r); self.assertIn('new_requests_not_settled',r); self.assertIn('superuser_reserved_connections=3',c); self.assertNotIn('failover',r.lower()); self.assertNotIn('ap-server-2へ',r)
 def test_settled_snapshot_below_peak_with_real_postgres_fatal(self):
  with tempfile.TemporaryDirectory() as folder:
   art=Path(folder)
   documents={
    'old-connections.json':{'matched_count':10,'pg_rows':[{}]*10},
    'ap2-state.json':{'accepted':12,'connected':4,'failed':8},
    'db-capacity.json':{'max_connections':20,'superuser_reserved_connections':3,'numbackends':17,'ap_server_1':10,'ap_server_2':4,'management':2},
    'db-continuity.json':{'unchanged':True},'cleanup.json':{'verified':True},
   }
   for name,value in documents.items(): (art/name).write_text(json.dumps(value),encoding='utf-8')
   (art/'db.log').write_text('FATAL: sorry, too many clients already\n',encoding='utf-8')
   result=subprocess.run([sys.executable,str(ROOT/'scripts/test06-validate.py'),str(art)],capture_output=True,text=True)
   self.assertEqual(0,result.returncode,result.stderr)
if __name__=='__main__': unittest.main()
