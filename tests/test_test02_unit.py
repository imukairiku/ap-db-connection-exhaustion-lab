import py_compile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class Test02PreparationTests(unittest.TestCase):
    def test_python_sources_compile(self):
        py_compile.compile(ROOT / "phase1/test02/app.py", doraise=True)
        py_compile.compile(ROOT / "scripts/test02-counter.py", doraise=True)

    def test_scope_is_single_normal_request(self):
        runner = (ROOT / "tests/test-02.sh").read_text(encoding="utf-8")
        compose = (ROOT / "tests/test-02.compose.yml").read_text(encoding="utf-8")
        app = (ROOT / "phase1/test02/app.py").read_text(encoding="utf-8")
        self.assertNotIn("docker pause", runner)
        self.assertNotIn("iptables", runner)
        self.assertNotIn("ap-server-2", compose)
        self.assertNotIn("/batches", app)
        self.assertIn("INSERT INTO business_results", app)
        self.assertIn("connection.commit()", app)


if __name__ == "__main__":
    unittest.main()
