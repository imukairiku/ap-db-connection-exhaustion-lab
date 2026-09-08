import py_compile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class Test06Preparation(unittest.TestCase):
 def test_python(self):
  for p in ('phase2/test06/app.py','phase2/test06/hold-admin.py','scripts/test06-counter.py','scripts/test06-validate.py'): py_compile.compile(ROOT/p,doraise=True)
 def test_real_capacity_scope(self):
  r=(ROOT/'tests/test-06.sh').read_text(); c=(ROOT/'tests/test-06.compose.yml').read_text(); self.assertIn("current_setting('max_connections')",r); self.assertIn('new_requests_not_settled',r); self.assertIn('superuser_reserved_connections=3',c); self.assertNotIn('failover',r.lower()); self.assertNotIn('ap-server-2へ',r)
if __name__=='__main__': unittest.main()
