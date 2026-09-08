import py_compile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

class Test03PreparationTests(unittest.TestCase):
    def test_python_sources_compile(self):
        py_compile.compile(ROOT / "phase1/test03/app.py", doraise=True)
        py_compile.compile(ROOT / "scripts/test03-counter.py", doraise=True)

    def test_scope_and_parallel_limit(self):
        app = (ROOT / "phase1/test03/app.py").read_text(encoding="utf-8")
        runner = (ROOT / "tests/test-03.sh").read_text(encoding="utf-8")
        compose = (ROOT / "tests/test-03.compose.yml").read_text(encoding="utf-8")
        self.assertIn("BoundedSemaphore(12)", app)
        self.assertIn("max_workers=12", runner)
        self.assertIn("db_connections=12", runner)
        self.assertNotIn("docker pause", runner)
        self.assertNotIn("iptables", runner)
        self.assertNotIn("ap-server-2", compose)

if __name__ == "__main__":
    unittest.main()
