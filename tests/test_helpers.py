"""Exercise the real embedded launcher/stopper against a fake game process."""
import ast
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'setup-zomboid.sh'
TEXT = SCRIPT.read_text()
def embedded(tag):
    return TEXT.split("<<'" + tag + "'\n", 1)[1].split('\n' + tag + '\n', 1)[0]

class Helpers(unittest.TestCase):
    def test_shell_and_python_syntax(self):
        subprocess.run(['bash', '-n', str(SCRIPT)], check=True)
        for tag in ('PY_START', 'PY_STOP'):
            ast.parse(embedded(tag))

    def exercise(self, existing_admin):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            root, home, runtime = (base / name for name in ('server', 'home', 'run'))
            for directory in (root, home, runtime):
                directory.mkdir()
            os.mkfifo(runtime / 'console')
            password = 'test-only-$(do-not-execute);password'
            (home / 'admin-password.txt').write_text(password + '\n')
            if existing_admin:
                (home / 'Zomboid/db').mkdir(parents=True)
                with sqlite3.connect(home / 'Zomboid/db/servertest.db') as conn:
                    conn.execute('CREATE TABLE whitelist (username TEXT)')
                    conn.execute("INSERT INTO whitelist VALUES ('admin')")
            fake = root / 'ProjectZomboid64'
            fake.write_text('#!/usr/bin/python3\nimport json,sys\nfrom pathlib import Path\n'
                            'Path("args.json").write_text(json.dumps(sys.argv[1:]))\n'
                            'line=sys.stdin.readline()\nPath("shutdown.txt").write_text(line)\n')
            fake.chmod(0o755)
            def relocate(code):
                return code.replace('/opt/zomboid/server', str(root)).replace('/var/lib/zomboid', str(home)).replace('/run/zomboid', str(runtime))
            start, stop = base / 'start.py', base / 'stop.py'
            start.write_text(relocate(embedded('PY_START')))
            stop.write_text(relocate(embedded('PY_STOP')))
            with subprocess.Popen(['python3', str(start)], stderr=subprocess.DEVNULL) as proc:
                try:
                    deadline = time.monotonic() + 5
                    while not (root / 'args.json').exists():
                        if proc.poll() is not None or time.monotonic() > deadline:
                            self.fail('Launcher did not start the fake server')
                        time.sleep(.05)
                    args = json.loads((root / 'args.json').read_text())
                    expected = ['-servername', 'servertest']
                    if not existing_admin:
                        expected += ['-adminpassword', password]
                    self.assertEqual(args, expected)
                    with subprocess.Popen(['python3', str(stop), str(proc.pid)]) as stopper:
                        self.assertEqual(proc.wait(timeout=5), 0)
                        self.assertEqual(stopper.wait(timeout=5), 0)
                    self.assertEqual((root / 'shutdown.txt').read_text(), 'quit\n')
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait()

    def test_new_admin_and_graceful_shutdown(self):
        self.exercise(False)

    def test_existing_admin_not_reset(self):
        self.exercise(True)

if __name__ == '__main__':
    unittest.main()
