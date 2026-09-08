import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class Test01LocalRegressionTests(unittest.TestCase):
    def test_counter_stops_after_three_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            for attempt in range(3):
                result = subprocess.run(
                    [sys.executable, str(ROOT / "scripts/test01-counter.py"), str(state),
                     "finish", f"run-{attempt}", "artifact", "FAIL", "fixture"],
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(0, result.returncode, result.stderr)
            gate = subprocess.run(
                [sys.executable, str(ROOT / "scripts/test01-counter.py"), str(state), "gate"],
                capture_output=True, text=True, check=False,
            )
            self.assertNotEqual(0, gate.returncode)
            document = json.loads(state.read_text(encoding="utf-8"))
            self.assertEqual(3, document["consecutive_failures"])
            self.assertTrue(document["stopped"])

    def test_embedded_python_compiles(self):
        path = ROOT / "tests/test-01.sh"
        lines = path.read_text(encoding="utf-8").splitlines()
        index = blocks = 0
        while index < len(lines):
            if "<<'PY'" not in lines[index]:
                index += 1
                continue
            end = index + 1
            while end < len(lines) and lines[end] != "PY":
                end += 1
            self.assertLess(end, len(lines), f"unterminated heredoc at line {index + 1}")
            compile("\n".join(lines[index + 1:end]) + "\n", str(path), "exec")
            blocks += 1
            index = end + 1
        self.assertGreater(blocks, 0)

    def test_runner_is_limited_to_test01_compose(self):
        runner = (ROOT / "tests/test-01.sh").read_text(encoding="utf-8")
        compose = (ROOT / "tests/test-01.compose.yml").read_text(encoding="utf-8")
        self.assertIn('tests/test-01.compose.yml', runner)
        self.assertNotIn("inject-failure", runner)
        self.assertNotIn("docker pause", runner)
        self.assertNotIn("ap-server-2:", compose)
        self.assertNotIn("ap-netadmin-1:", compose)


if __name__ == "__main__":
    unittest.main()
