#!/usr/bin/env python3
"""Servo preflight. Read-only by default; --power-test briefly powers servos.

Close Stanbot first. Power test requires a supervised, clear robot and sends
torque-off only, never position goals. Firmware owns the cutoff, not this host.
"""
import argparse
import json
import os
import select
import termios
import time


def validate_session(movement, legs, power, ramp=False):
    """Measurement completion is NOT target accuracy or physical calibration."""
    if not movement or movement.get("result") != "session_measured":
        raise RuntimeError("Session incomplete; do not retry automatically")
    start = movement.get("start", -1)
    if not (430 <= start <= 480 and movement.get("stable_samples") == 4
            and 430 <= movement.get("stable_min", -1) <= start <= movement.get("stable_max", -1) <= 480
            and movement["stable_max"] - movement["stable_min"] <= 3
            and movement.get("goal") == start and power.get("position_commands") == (17 if ramp else 3)
            and 0 < power.get("elapsed_ms", 0) <= 5000):
        raise RuntimeError("Session envelope invalid")
    if set(legs) != {0, 1}:
        raise RuntimeError("Session legs missing")
    for index, goal in enumerate((start - 8, start)):
        leg = legs[index]
        if not (leg.get("complete") is True and leg.get("goal") == goal
                and start - 11 <= leg.get("last", -1) <= start + 3
                and (index != 0 or leg.get("last", -1) <= start - 2)
                and 5 <= leg.get("samples", 0) <= 50 and 0 <= leg.get("tail_spread", -1) <= 2):
            raise RuntimeError("Session leg invalid")


def validate_sweep(movement, legs, power, expected_legs=4, servo=1):
    """Completion means every leg ran with verified writes and no guard trip.

    Arrival within a few raw steps is reported per leg, not required: the servo
    settles short by design (see servo-startup-review.md). Physical observation
    of direction and smoothness still comes from the user.
    """
    if not movement or movement.get("result") != "sweep_complete":
        raise RuntimeError("Motion did not complete: %s" % (movement or {}).get("result"))
    if movement.get("legs_done") != expected_legs or set(legs) != set(range(expected_legs)):
        raise RuntimeError("Motion legs missing")
    if movement.get("servo", 1) != servo or movement.get("legs_planned", expected_legs) != expected_legs:
        raise RuntimeError("Motion plan mismatch")
    low, high = movement.get("envelope_low", -1), movement.get("envelope_high", -1)
    if not (0 < low < high <= 1023 and low <= movement.get("start", -1) <= high
            and 0 < power.get("elapsed_ms", 0) <= 20000):
        raise RuntimeError("Motion envelope invalid")
    for index in range(expected_legs):
        leg = legs[index]
        if not (low <= leg.get("final", -1) <= high and 0 < leg.get("duration_ms", 0) <= 6000):
            raise RuntimeError("Motion leg invalid")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", help="Previously verified StackChan USB port")
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--power-test", action="store_true", help="Explicitly authorize one bounded motor-power window")
    actions.add_argument("--disable-only", action="store_true", help="Disable motor power once; never re-enable or command movement")
    actions.add_argument("--yaw-test", action="store_true", help="Supervised small yaw movement with automatic cutoff")
    actions.add_argument("--yaw-back", action="store_true", help="Supervised opposite-direction eight-step yaw movement")
    actions.add_argument("--yaw-session", action="store_true", help="Supervised eight-step rightward movement and conditional return; four-second cutoff")
    actions.add_argument("--yaw-ramp", action="store_true", help="Same supervised session using eight gradual waypoints per leg")
    actions.add_argument("--yaw-sweep", action="store_true", help="Supervised full sweep: center, 90 deg robot-left, 90 deg robot-right, center; 20-second cutoff")
    actions.add_argument("--center", action="store_true", help="Supervised move of yaw to the factory center only")
    actions.add_argument("--pitch-nudge", action="store_true", help="First supervised pitch motion: +16 raw (5 deg) from rest and back")
    actions.add_argument("--reboot", action="store_true", help="Ask the firmware to restart so a fresh once-per-boot power window is available")
    args = parser.parse_args()
    session = args.yaw_session or args.yaw_ramp
    plan_motion = args.yaw_sweep or args.center or args.pitch_nudge
    yaw_motion = args.yaw_test or args.yaw_back or session or plan_motion
    powered = args.power_test or yaw_motion
    fd = os.open(args.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    old = termios.tcgetattr(fd)
    raw = termios.tcgetattr(fd)
    raw[0] = raw[1] = raw[3] = 0
    raw[2] |= termios.CLOCAL | termios.CREAD
    termios.tcsetattr(fd, termios.TCSANOW, raw)
    try:
        os.write(fd, b"X\n")
        end = time.monotonic() + 2
        while time.monotonic() < end:
            if select.select([fd], [], [], 0.1)[0]:
                if not os.read(fd, 65536):
                    raise RuntimeError("USB disconnected")
        if args.reboot:
            os.write(fd, b"C,REBOOT\n")
            # The port disappears as the device restarts; that is success here.
            time.sleep(0.5)
            print("Reboot requested; wait for the device to re-enumerate.")
            return
        os.write(fd, b"C,REBOOT\n" if args.reboot else b"C,CENTER\n" if args.center else b"C,PITCHNUDGE\n" if args.pitch_nudge else b"C,YAWSWEEP\n" if args.yaw_sweep else b"C,YAWRAMP\n" if args.yaw_ramp else b"C,YAWSESSION\n" if session else b"C,POWEROFF\n" if args.disable_only else b"C,YAWBACK\n" if args.yaw_back else b"C,YAWTEST\n" if args.yaw_test else b"C,POWERTEST\n" if args.power_test else b"Q\n")
        buffer = bytearray()
        records = {}
        power = None
        disabled = None
        movement = None
        legs = {}
        end = time.monotonic() + (25 if args.yaw_sweep else 12 if plan_motion else 8 if session else 5)
        while time.monotonic() < end and (disabled is None if args.disable_only else
                (len(records) < 2 or (powered and power is None))):
            if not select.select([fd], [], [], 0.1)[0]:
                continue
            data = os.read(fd, 4096)
            if not data:
                raise RuntimeError("USB disconnected")
            buffer.extend(data)
            if len(buffer) > 8192:
                raise RuntimeError("Unexpected diagnostic output")
            while b"\n" in buffer:
                line, _, remainder = buffer.partition(b"\n")
                buffer = bytearray(remainder)
                if line.startswith(b"SBLG "):
                    leg = json.loads(line[5:])
                    if leg.get("leg") in legs:
                        raise RuntimeError("Duplicate session leg")
                    legs[leg.get("leg")] = leg
                    print(json.dumps(leg), flush=True)
                elif line.startswith(b"SBSC "):
                    record = json.loads(line[5:])
                    print(json.dumps(record), flush=True)
                    if record.get("id") in (1, 2):
                        records[record["id"]] = record
                elif line.startswith(b"SBPD "):
                    # Firmware buffers these snapshots until after cutoff.
                    # Diagnostic evidence only, never a substitute for SBPW.
                    print(json.dumps(json.loads(line[5:])), flush=True)
                elif line.startswith(b"SBPW "):
                    power = json.loads(line[5:])
                    print(json.dumps(power), flush=True)
                    if "error" in power:
                        raise RuntimeError("Power preflight refused or failed; do not retry automatically")
                elif line.startswith(b"SBOF "):
                    disabled = json.loads(line[5:])
                    print(json.dumps(disabled), flush=True)
                elif line.startswith(b"SBMV "):
                    movement = json.loads(line[5:])
                    print(json.dumps(movement), flush=True)
        if args.disable_only:
            if not disabled or "error" in disabled or not (
                    disabled.get("off_write_ack") is True and
                    disabled.get("output_latch_low_verified") is True):
                raise RuntimeError("Disable NOT confirmed; do not retry automatically or assume motor power is off")
            print("Disable latch confirmed; physical supply-off is NOT verified. No re-enable requested.")
            return
        if powered and (power is None or power.get("disable_latch_low_verified") is not True):
            raise RuntimeError("DISABLE LATCH NOT VERIFIED: physically power off the robot")
        if powered and not (power.get("power_write_ack") is True and power.get("enable_latch_high_verified") is True):
            raise RuntimeError("Motor-enable latch NOT verified; calibration must stay locked")
        if len(records) != 2:
            raise RuntimeError("Incomplete servo preflight")
        for record in records.values():
            if not (0 <= record["position"] <= 1000 and record["torque"] in ((0,) if powered else (0, 1))
                    and 0 <= record["minimum"] < record["maximum"] <= 1023
                    and record["moving"] == 0):
                raise RuntimeError("Servo preflight NOT passed; do not enable motion")
        print("Feedback received; physical calibration still required.")
        if plan_motion:
            validate_sweep(movement, legs, power, expected_legs=4 if args.yaw_sweep else 1 if args.center else 2,
                           servo=2 if args.pitch_nudge else 1)
            print("Plan completed with verified writes; direction and smoothness need your observation.")
        elif session:
            validate_session(movement, legs, power, args.yaw_ramp)
            print("Bounded session measured; target accuracy and physical behavior still require review.")
        elif yaw_motion:
            if not movement or movement.get("result") != "target_feedback_received":
                raise RuntimeError("Yaw target NOT confirmed; do not repeat automatically")
            if not (430 <= movement["start"] <= 480 and movement["goal"] == movement["start"] + (-8 if args.yaw_back else 8)
                    and movement.get("stable_samples") == 4
                    and 430 <= movement.get("stable_min", -1) <= movement["start"] <= movement.get("stable_max", -1) <= 480
                    and movement["stable_max"] - movement["stable_min"] <= 3
                    and abs(movement["last_position"] - movement["goal"]) <= 2):
                raise RuntimeError("Yaw feedback outside expected guard")
            print("Small yaw target feedback received; user observation still required.")
        if powered:
            print("Enable/disable latch checks passed; physical supply-off is NOT independently verified.")
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, old)
        os.close(fd)


if __name__ == "__main__":
    main()
