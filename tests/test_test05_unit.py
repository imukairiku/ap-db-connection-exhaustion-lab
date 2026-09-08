import py_compile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class Test05Preparation(unittest.TestCase):
 def test_python(self):
  for p in ('scripts/test05-counter.py','scripts/test05-validate.py'): py_compile.compile(ROOT/p,doraise=True)
 def test_scope(self):
  r=(ROOT/'tests/test-05.sh').read_text(); self.assertIn('observe immediate_after',r); self.assertIn('observe after_5s',r); self.assertIn('observe after_15s',r); self.assertIn('cleanup-backend.sql',r); self.assertNotIn('ap-server-2',r)
if __name__=='__main__': unittest.main()
