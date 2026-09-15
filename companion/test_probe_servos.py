import json
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import time
import unittest
from probe_servos import validate_session, validate_sweep


class ProbeTests(unittest.TestCase):
    def simulate_disable(self, result):
        master, slave = pty.openpty()
        process = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name("probe_servos.py")), os.ttyname(slave), "--disable-only"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            received = b""
            end = time.monotonic() + 5
            while b"C,POWEROFF\n" not in received and time.monotonic() < end:
                if select.select([master], [], [], 0.1)[0]:
                    received += os.read(master, 4096)
            self.assertEqual(received, b"X\nC,POWEROFF\n")
            os.write(master, ("SBOF " + json.dumps(result) + "\n").encode())
            stdout, stderr = process.communicate(timeout=3)
            return process.returncode, stdout + stderr
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            os.close(master)
            os.close(slave)

    def test_disable_latch_is_not_rail_verification(self):
        code, output = self.simulate_disable(dict(off_write_ack=True, output_latch_low_verified=True,
                                                  rail_off_verified=False))
        self.assertEqual(code, 0)
        self.assertIn("physical supply-off is NOT verified", output)

    def test_disable_ack_alone_fails(self):
        code, output = self.simulate_disable(dict(off_write_ack=True, output_latch_low_verified=False))
        self.assertNotEqual(code, 0)
        self.assertIn("Disable NOT confirmed", output)

    def test_disable_error_fails(self):
        code, _ = self.simulate_disable(dict(error="base_unavailable"))
        self.assertNotEqual(code, 0)

    def simulate(self, position=500, off=True, high=True, torque=0, movement=None, backwards=False, session=False, ramp=False):
        session = session or ramp
        master, slave = pty.openpty()
        process = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name("probe_servos.py")), os.ttyname(slave),
             "--yaw-ramp" if ramp else "--yaw-session" if session else "--yaw-back" if backwards else "--yaw-test" if movement is not None else "--power-test"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            received = b""
            command = b"C,YAWRAMP\n" if ramp else b"C,YAWSESSION\n" if session else b"C,YAWBACK\n" if backwards else b"C,YAWTEST\n" if movement is not None else b"C,POWERTEST\n"
            end = time.monotonic() + 5
            while command not in received and time.monotonic() < end:
                if select.select([master], [], [], 0.1)[0]:
                    received += os.read(master, 4096)
            self.assertEqual(received, b"X\n" + command)
            for phase, level in (("immediate", 0), ("settled", int(high)), ("after_cutoff", 0)):
                snapshot = dict(phase=phase, mode=1, latch=level, input=0,
                                mode_error=0, latch_error=0, input_error=0)
                os.write(master, ("SBPD " + json.dumps(snapshot) + "\n").encode())
            for servo in (1, 2):
                record = dict(id=servo, position=position, torque=torque, minimum=0, maximum=1000, moving=0)
                os.write(master, ("SBSC " + json.dumps(record) + "\n").encode())
            if movement is not None:
                if session:
                    for leg in (0, 1):
                        os.write(master, ("SBLG " + json.dumps(dict(leg=leg, goal=movement["start"] - (8 if leg == 0 else 0),
                          last=movement["start"] - (4 if leg == 0 else 1), samples=37, tail_spread=1, complete=True)) + "\n").encode())
                for elapsed in range(0, 400, 20):
                    os.write(master, ("SBPD " + json.dumps(dict(phase="yaw_trace", elapsed_ms=elapsed,
                                                                 position=460, moving=0)) + "\n").encode())
                os.write(master, ("SBMV " + json.dumps(movement) + "\n").encode())
            os.write(master, ("SBPW " + json.dumps(dict(power_write_ack=True, enable_latch_high_verified=high, disable_latch_low_verified=off, rail_off_verified=False, position_commands=17 if ramp else 3, elapsed_ms=3400)) + "\n").encode())
            stdout, stderr = process.communicate(timeout=3)
            return process.returncode, stdout + stderr
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            os.close(master)
            os.close(slave)

    def test_valid_feedback_and_cutoff(self):
        code, output = self.simulate()
        self.assertEqual(code, 0)
        self.assertIn('"phase": "immediate"', output)
        self.assertIn('"phase": "settled"', output)
        self.assertIn('"phase": "after_cutoff"', output)
        self.assertIn("physical supply-off is NOT independently verified", output)

    def test_session_protocol(self):
        code, output = self.simulate(session=True, movement=dict(result="session_measured", start=477, goal=477,
            stable_samples=4, stable_min=477, stable_max=477))
        self.assertEqual(code, 0, output)
        self.assertIn("target accuracy and physical behavior still require review", output)

    def test_ramp_protocol(self):
        code, output = self.simulate(ramp=True, movement=dict(result="session_measured", start=473, goal=473,
            stable_samples=4, stable_min=473, stable_max=473))
        self.assertEqual(code, 0, output)

    def test_session_disable_failure(self):
        code, output = self.simulate(session=True, off=False, movement=dict(result="session_measured", start=477, goal=477))
        self.assertNotEqual(code, 0)
        self.assertIn("DISABLE LATCH NOT VERIFIED", output)

    def test_session_validation_failures(self):
        movement = dict(result="session_measured", start=477, goal=477, stable_samples=4, stable_min=477, stable_max=477)
        legs = {i: dict(goal=469 if i == 0 else 477, last=473 if i == 0 else 476, samples=37, tail_spread=1, complete=True) for i in (0, 1)}
        power = dict(position_commands=3, elapsed_ms=3400)
        validate_session(movement, legs, power)
        for field, value in (("complete", False), ("goal", 485), ("last", 500), ("samples", 0), ("tail_spread", 4)):
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                validate_session(movement, {0: dict(legs[0], **{field: value}), 1: legs[1]}, power)
        with self.assertRaises(RuntimeError):
            validate_session(movement, {0: legs[0]}, power)
        with self.assertRaises(RuntimeError):
            validate_session(dict(movement, result="session_unsettled_or_deadline"), legs, power)
        with self.assertRaises(RuntimeError):
            validate_session(movement, legs, dict(power, position_commands=4))

    def test_torque_on_still_fails(self):
        code, output = self.simulate(torque=1)
        self.assertNotEqual(code, 0)
        self.assertIn("NOT passed", output)

    def test_yaw_feedback_requires_expected_target(self):
        code, output = self.simulate(movement=dict(result="target_feedback_received", start=456, goal=464, last_position=464,
                                                  stable_samples=4, stable_min=455, stable_max=456))
        self.assertEqual(code, 0)
        self.assertIn("user observation still required", output)
        self.assertIn('"phase": "yaw_trace"', output)

    def test_yaw_confirmed_center_434(self):
        code, _ = self.simulate(movement=dict(result="target_feedback_received", start=434, goal=442, last_position=442,
                                             stable_samples=4, stable_min=434, stable_max=434))
        self.assertEqual(code, 0)

    def test_yaw_back_expected_target(self):
        code, _ = self.simulate(backwards=True, movement=dict(result="target_feedback_received", start=477, goal=469,
                              last_position=469, stable_samples=4, stable_min=477, stable_max=477))
        self.assertEqual(code, 0)

    def test_yaw_back_wrong_direction_fails(self):
        code, _ = self.simulate(backwards=True, movement=dict(result="target_feedback_received", start=470, goal=478,
                              last_position=478, stable_samples=4, stable_min=470, stable_max=470))
        self.assertNotEqual(code, 0)

    def test_yaw_unstable_feedback_fails(self):
        code, _ = self.simulate(movement=dict(result="target_feedback_received", start=434, goal=442, last_position=442,
                                             stable_samples=4, stable_min=430, stable_max=434))
        self.assertNotEqual(code, 0)

    def test_yaw_missing_stability_fails(self):
        code, _ = self.simulate(movement=dict(result="target_feedback_received", start=434, goal=442, last_position=442))
        self.assertNotEqual(code, 0)

    def test_yaw_below_guard_fails(self):
        code, _ = self.simulate(movement=dict(result="target_feedback_received", start=429, goal=437, last_position=437,
                                             stable_samples=4, stable_min=429, stable_max=429))
        self.assertNotEqual(code, 0)

    def test_yaw_refusal_fails(self):
        code, _ = self.simulate(movement=dict(result="preflight_refused"))
        self.assertNotEqual(code, 0)

    def test_yaw_wrong_target_fails(self):
        code, _ = self.simulate(movement=dict(result="target_feedback_received", start=456, goal=564, last_position=564))
        self.assertNotEqual(code, 0)

    def test_yaw_cutoff_failure_fails(self):
        code, output = self.simulate(off=False, movement=dict(result="target_feedback_received", start=456, goal=464, last_position=464))
        self.assertNotEqual(code, 0)
        self.assertIn("DISABLE LATCH NOT VERIFIED", output)

    def test_missing_position_fails_closed(self):
        code, output = self.simulate(position=-1)
        self.assertNotEqual(code, 0)
        self.assertIn("NOT passed", output)

    def test_unverified_cutoff_is_explicit(self):
        code, output = self.simulate(off=False)
        self.assertNotEqual(code, 0)
        self.assertIn("DISABLE LATCH NOT VERIFIED", output)

    def test_ack_without_high_signal_fails(self):
        code, output = self.simulate(high=False)
        self.assertNotEqual(code, 0)
        self.assertIn("Motor-enable latch NOT verified", output)


class SweepValidationTest(unittest.TestCase):
    def setUp(self):
        self.movement = {"result": "sweep_complete", "start": 458, "last_position": 457,
                         "legs_done": 4, "legs_planned": 4, "servo": 1,
                         "envelope_low": 156, "envelope_high": 764}
        names = ("center", "robot_left", "robot_right", "center")
        finals = (459, 176, 745, 457)
        self.legs = {i: {"leg": i, "name": n, "goal": g, "final": f, "error": f - g,
                         "duration_ms": 2500, "arrived": True}
                     for i, (n, g, f) in enumerate(zip(names, (460, 172, 748, 460), finals))}
        self.power = {"elapsed_ms": 12000, "position_commands": 150}

    def test_valid_sweep(self):
        validate_sweep(self.movement, self.legs, self.power)

    def test_incomplete_or_guarded_fails(self):
        for result in ("stall_detected", "feedback_outside_envelope", "cutoff_before_completion", "preflight_refused"):
            with self.assertRaises(RuntimeError):
                validate_sweep(dict(self.movement, result=result), self.legs, self.power)
        with self.assertRaises(RuntimeError):
            validate_sweep(dict(self.movement, legs_done=3), {k: v for k, v in self.legs.items() if k < 3}, self.power)
        with self.assertRaises(RuntimeError):
            validate_sweep(self.movement, {**self.legs, 1: dict(self.legs[1], final=100)}, self.power)

    def test_wrong_servo_or_leg_count_fails(self):
        with self.assertRaises(RuntimeError):
            validate_sweep(self.movement, self.legs, self.power, expected_legs=4, servo=2)
        with self.assertRaises(RuntimeError):
            validate_sweep(self.movement, self.legs, self.power, expected_legs=2)

    def test_pitch_nudge_shape(self):
        movement = {"result": "sweep_complete", "start": 620, "last_position": 621,
                    "legs_done": 2, "legs_planned": 2, "servo": 2,
                    "envelope_low": 604, "envelope_high": 652}
        legs = {0: {"leg": 0, "name": "pitch_plus16", "goal": 636, "final": 632, "error": -4,
                    "duration_ms": 1400, "arrived": True},
                1: {"leg": 1, "name": "pitch_return", "goal": 620, "final": 621, "error": 1,
                    "duration_ms": 1400, "arrived": True}}
        validate_sweep(movement, legs, {"elapsed_ms": 6000}, expected_legs=2, servo=2)


if __name__ == "__main__":
    unittest.main()
