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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", help="Previously verified StackChan USB port")
    parser.add_argument("--power-test", action="store_true", help="Explicitly authorize one bounded motor-power window")
    args = parser.parse_args()
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
        os.write(fd, b"C,POWERTEST\n" if args.power_test else b"Q\n")
        buffer = bytearray()
        records = {}
        power = None
        end = time.monotonic() + 5
        while time.monotonic() < end and (len(records) < 2 or (args.power_test and power is None)):
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
                if line.startswith(b"SBSC "):
                    record = json.loads(line[5:])
                    print(json.dumps(record), flush=True)
                    if record.get("id") in (1, 2):
                        records[record["id"]] = record
                elif line.startswith(b"SBPW "):
                    power = json.loads(line[5:])
                    print(json.dumps(power), flush=True)
                    if "error" in power:
                        raise RuntimeError("Power preflight refused or failed; do not retry automatically")
        if args.power_test and (power is None or not power.get("power_off_verified")):
            raise RuntimeError("POWER OFF NOT VERIFIED: physically power off the robot")
        if args.power_test and not (power.get("power_write_ack") and power.get("enable_high_verified")):
            raise RuntimeError("Motor-enable high NOT verified; calibration must stay locked")
        if len(records) != 2:
            raise RuntimeError("Incomplete servo preflight")
        for record in records.values():
            if not (0 <= record["position"] <= 1000 and record["torque"] in ((0,) if args.power_test else (0, 1))
                    and 0 <= record["minimum"] < record["maximum"] <= 1023
                    and record["moving"] == 0):
                raise RuntimeError("Servo preflight NOT passed; do not enable motion")
        print("Feedback received; physical calibration still required.")
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, old)
        os.close(fd)


if __name__ == "__main__":
    main()
