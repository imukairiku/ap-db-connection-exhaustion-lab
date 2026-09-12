import json
import py_compile
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class Test07Preparation(unittest.TestCase):
    def test_python_compiles_and_scope(self):
        for name in ('phase2/test06/app.py', 'scripts/test07-counter.py',
                     'scripts/test07-validate.py'):
            py_compile.compile(ROOT / name, doraise=True)
        runner = (ROOT / 'tests/test-07.sh').read_text(encoding='utf-8')
        self.assertIn('tests/test-06.compose.yml', runner)
        self.assertNotIn('tests/test-06.sh', runner)
        self.assertNotIn('scripts/test06-counter.py', runner)
        self.assertNotIn('failover', runner.lower())

    def test_validator_requires_real_connect_error_and_request_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            artifact = Path(folder)
            documents = {
                'old-connections.json': {'matched_count': 10},
                'ap2-state.json': {'accepted': 12, 'connected': 5, 'failed': 7,
                                   'requests': [
                                       {'request_id': f'req-{i}', 'state': 'CONNECTION_FAILED',
                                        'error_phase': 'connect'} for i in range(7)]},
                'db-capacity.json': {'max_connections': 20, 'ap_server_1': 10,
                                     'ap_server_2': 5, 'management': 2},
                'db-continuity.json': {'unchanged': True},
                'cleanup.json': {'verified': True},
            }
            for name, value in documents.items():
                (artifact / name).write_text(json.dumps(value), encoding='utf-8')
            message = 'FATAL: remaining connection slots are reserved for roles with the SUPERUSER attribute'
            (artifact / 'db.log').write_text(message + '\n', encoding='utf-8')
            rows = [{'request_id': f'req-{i}', 'ap': 'ap-server-2',
                     'event': 'CONNECTION_FAILED', 'error_phase': 'connect',
                     'error_type': 'OperationalError', 'db_error': message} for i in range(7)]
            (artifact / 'ap2.log').write_text('\n'.join(map(json.dumps, rows)) + '\n', encoding='utf-8')
            command = [sys.executable, str(ROOT / 'scripts/test07-validate.py'), str(artifact)]
            self.assertEqual(0, subprocess.run(command, capture_output=True).returncode)
            rows[0]['db_error'] = 'dummy error'
            (artifact / 'ap2.log').write_text('\n'.join(map(json.dumps, rows)) + '\n', encoding='utf-8')
            self.assertNotEqual(0, subprocess.run(command, capture_output=True).returncode)


if __name__ == '__main__':
    unittest.main()
