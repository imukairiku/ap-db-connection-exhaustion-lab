import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts' / 'test13-poll.py'


class PollTest(unittest.TestCase):
    def run_poll(self, content):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'ap.log'
            path.write_text(content, encoding='utf-8')
            return subprocess.run([sys.executable, str(SCRIPT), str(path)],
                                  capture_output=True, text=True)

    def test_pending_is_quiet(self):
        result = self.run_poll(json.dumps({'event': 'BACKOFF_START', 'attempt': 2, 'seconds': 2}) + '\n')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, '')

    def test_ready(self):
        result = self.run_poll(json.dumps({'event': 'BACKOFF_START', 'attempt': 3, 'seconds': 4}) + '\n')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, '')

    def test_malformed_evidence_is_error(self):
        result = self.run_poll('{not-json}\n')
        self.assertEqual(result.returncode, 2)
        self.assertIn('polling evidence error', result.stderr)


if __name__ == '__main__':
    unittest.main()
