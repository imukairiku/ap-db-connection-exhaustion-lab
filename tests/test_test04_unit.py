import json,py_compile,subprocess,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class Test04Preparation(unittest.TestCase):
 def test_python(self):
  for path in ('phase1/test04/app.py','scripts/test04-snapshot.py','scripts/test04-counter.py'): py_compile.compile(ROOT/path,doraise=True)
 def test_scope_and_order(self):
  runner=(ROOT/'tests/test-04.sh').read_text(); compose=(ROOT/'tests/test-04.compose.yml').read_text()
  self.assertLess(runner.index('OUTPUT_DROP'),runner.index('INPUT_DROP')); self.assertLess(runner.index('RULES_VERIFIED'),runner.index('PAUSE_VERIFIED'))
  self.assertIn("matched_count']==12",runner); self.assertNotIn('after_5s',runner); self.assertNotIn('after_15s',runner); self.assertNotIn('ap-server-2',compose)
 def test_snapshot_correlates_pg_and_ss(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory); pg=root/'pg'; ss=root/'ss'; out=root/'out.json'
   pg.write_text('101|172.20.0.2|41001|2026-09-08 17:00:00+00|idle in transaction\n',encoding='utf-8')
   ss.write_text('0 0 172.20.0.3:5432 172.20.0.2:41001\n',encoding='utf-8')
   result=subprocess.run([sys.executable,str(ROOT/'scripts/test04-snapshot.py'),str(pg),str(ss),str(out)],capture_output=True,text=True)
   self.assertEqual(0,result.returncode,result.stderr); self.assertEqual([101],json.loads(out.read_text())['matched_pids'])
if __name__=='__main__': unittest.main()
