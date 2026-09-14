import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import time
import unittest


class ProbeTests(unittest.TestCase):
    def simulate(self, position=500, off=True):
        master, slave = pty.openpty()
        process = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name("probe_servos.py")), os.ttyname(slave), "--power-test"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            received = b""
            end = time.monotonic() + 5
            while b"C,POWERTEST\n" not in received and time.monotonic() < end:
                if select.select([master], [], [], 0.1)[0]:
                    received += os.read(master, 4096)
            self.assertIn(b"C,POWERTEST\n", received)
            for servo in (1, 2):
                record = dict(id=servo, position=position, torque=0, minimum=0, maximum=1000, moving=0)
                os.write(master, ("SBSC " + json.dumps(record) + "\n").encode())
            os.write(master, ("SBPW " + json.dumps(dict(power_off_verified=off)) + "\n").encode())
            stdout, stderr = process.communicate(timeout=3)
            return process.returncode, stdout + stderr
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            os.close(master)
            os.close(slave)

    def test_valid_feedback_and_cutoff(self):
        code, _ = self.simulate()
        self.assertEqual(code, 0)

    def test_missing_position_fails_closed(self):
        code, output = self.simulate(position=-1)
        self.assertNotEqual(code, 0)
        self.assertIn("NOT passed", output)

    def test_unverified_cutoff_is_explicit(self):
        code, output = self.simulate(off=False)
        self.assertNotEqual(code, 0)
        self.assertIn("POWER OFF NOT VERIFIED", output)


if __name__ == "__main__":
    unittest.main()
