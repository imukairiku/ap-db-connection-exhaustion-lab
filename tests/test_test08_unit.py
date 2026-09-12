import py_compile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class Test08Preparation(unittest.TestCase):
    def test_python_compiles(self):
        for name in ('scripts/test08-monitor.py', 'scripts/test08-counter.py',
                     'scripts/test08-validate.py'):
            py_compile.compile(ROOT / name, doraise=True)

    def test_only_monitor_starts_secondary(self):
        runner = (ROOT / 'tests/test-08.sh').read_text(encoding='utf-8')
        monitor = (ROOT / 'scripts/test08-monitor.py').read_text(encoding='utf-8')
        self.assertIn("['up', '-d', '--build', 'ap-server-2']", monitor)
        self.assertNotIn('up -d --build ap-server-2', runner)
        self.assertIn('docker pause "$AP1"', runner)
        self.assertIn('artifacts/phase3/current.json', runner)
        self.assertNotIn('scripts/test07-counter.py', runner)


if __name__ == '__main__':
    unittest.main()
