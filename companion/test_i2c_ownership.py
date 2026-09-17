#!/usr/bin/env python3
"""The camera task owns the internal I2C bus. Nothing else may touch it.

On 2026-09-17 sleep called M5.Display.setBrightness, which reaches the AXP2101
with M5GFX's own I2C driver on the bus the camera task drives with i2c_master.
Two drivers on one port left it in ESP_ERR_INVALID_STATE: every transaction to
the base failed from the first sleep until the next reboot, so motor power could
not be switched and the light bar could not be written. Head following was dead
for hours, silently.

This test reads the sketch's source and fails if it calls anything in M5Unified
or Arduino that uses that bus. A call that really is safe carries a marker on
its own line saying why:

    M5.Power.powerOff();   // i2c-ok: nothing runs after it

Use the camera task's driver instead (see backlight.h for the pattern).
"""
import os
import re
import sys

SKETCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "firmware", "camera_stream")

# Calls that reach the internal I2C bus through a driver other than the camera
# task's. M5.begin / M5.config in setup() run before that task exists.
FORBIDDEN = [
    (r"\bM5\.Display\.setBrightness\s*\(", "backlight: use setBacklight() (backlight.h)"),
    (r"\bM5\.Lcd\.setBrightness\s*\(", "backlight: use setBacklight() (backlight.h)"),
    (r"\bM5\.update\s*\(", "polls touch and power over internal I2C"),
    (r"\bM5\.Power\.", "the AXP2101 is on internal I2C: write it through the camera task's driver"),
    (r"\bM5\.Imu\.", "the IMU is on internal I2C"),
    (r"\bM5\.Rtc\.", "the RTC is on internal I2C"),
    (r"\bM5\.Touch\.", "the touch controller is on internal I2C"),
    (r"\bM5\.In_I2C\.", "M5Unified's own driver for the internal bus"),
    (r"\bWire1?\.", "Arduino's I2C driver: the internal bus belongs to i2c_master in the camera task"),
]


def strip_comments(line, in_block):
    """Code on this line with comments removed, and whether a /* block is still open."""
    out = ""
    i = 0
    while i < len(line):
        if in_block:
            end = line.find("*/", i)
            if end < 0:
                return out, True
            i = end + 2
            in_block = False
        elif line.startswith("//", i):
            break
        elif line.startswith("/*", i):
            in_block = True
            i += 2
        else:
            out += line[i]
            i += 1
    return out, in_block


def violations(path):
    found = []
    in_block = False
    with open(path, encoding="utf-8") as source:
        for number, line in enumerate(source, 1):
            code, in_block = strip_comments(line, in_block)
            if "i2c-ok:" in line:
                continue
            for pattern, why in FORBIDDEN:
                if re.search(pattern, code):
                    found.append((path, number, line.strip(), why))
    return found


def main():
    # The guard must itself work: it catches the call that caused the outage, and
    # ignores the same words in a comment or behind a marker.
    probe = os.path.join(os.path.dirname(os.path.abspath(__file__)), "__i2c_probe.tmp")
    try:
        with open(probe, "w", encoding="utf-8") as f:
            f.write("M5.Display.setBrightness(0);\n")
            f.write("// M5.Display.setBrightness(0) is what broke it\n")
            f.write("M5.Power.powerOff();   // i2c-ok: nothing runs after it\n")
            f.write("/* M5.update(); */ int x = 0;\n")
        caught = violations(probe)
        assert len(caught) == 1 and caught[0][1] == 1, caught
    finally:
        if os.path.exists(probe):
            os.remove(probe)

    found = []
    for name in sorted(os.listdir(SKETCH)):
        if name.endswith((".ino", ".h", ".cpp")):
            found += violations(os.path.join(SKETCH, name))
    for path, number, line, why in found:
        print(f"{os.path.relpath(path)}:{number}: {line}\n    {why}", file=sys.stderr)
    if found:
        print("\nThe camera task owns the internal I2C bus; see this file's docstring.", file=sys.stderr)
        return 1
    print("i2c ownership: nothing in the sketch touches the internal bus behind the camera task's back")
    return 0


if __name__ == "__main__":
    sys.exit(main())
