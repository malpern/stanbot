#!/usr/bin/env python3
"""Hardware check: can the head still reach its base after sleeping and waking?

Run this after flashing any firmware that touches sleep, power, the display,
the light bar or I2C. It is the check that would have caught 2026-09-17, when
the first sleep after every boot left the internal I2C bus in
ESP_ERR_INVALID_STATE and head following dead until the next reboot, with
nothing to say so.

It needs the robot on USB (whichever port enumerates) and Stanbot closed. It
moves nothing: it reads the base through the firmware's read-only probe (Q),
sleeps and wakes the robot a few times, and reads the base again.

    python3 tools/check_sleep_wake.py                  # finds the port
    python3 tools/check_sleep_wake.py /dev/cu.usbmodem31201 --cycles 5

Exit 0: the base answered before and after. Exit 1: it did not.
"""
import argparse
import glob
import json
import os
import select
import subprocess
import sys
import time


def stanbot_running():
    return subprocess.run(["pgrep", "-f", "Stanbot.app/Contents/MacOS/Stanbot"],
                          capture_output=True).returncode == 0


def exchange(port, command, seconds):
    """Send one command and return what the robot says for `seconds`."""
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        os.write(fd, (command + "\n").encode())
        deadline = time.time() + seconds
        data = b""
        while time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.2)
            if ready:
                try:
                    data += os.read(fd, 65536)
                except BlockingIOError:
                    pass
        return data.decode("utf-8", "replace")
    finally:
        os.close(fd)


def base_status(port):
    """The base's line from the read-only probe: a dict, or None if it never came.

    Stops the stream first. Frames and text share this one USB channel, and only
    the frames carry a length, so a reply that arrives among JPEG data is
    shredded and the base line is simply lost. On 2026-09-17 that made this
    check report FAIL -- "the head cannot reach its base" -- about a robot whose
    base was answering perfectly well, because Stanbot had been killed mid
    stream and the robot went on sending frames to a viewer that no longer
    existed. A check that cries wolf about the one fault it exists to catch is
    worse than no check.
    """
    exchange(port, "X", 1)
    for line in exchange(port, "Q", 4).splitlines():
        if line.startswith("SBSC ") and '"base"' in line:
            try:
                return json.loads(line[5:])
            except json.JSONDecodeError:
                return None
    return None


def healthy(status):
    return bool(status) and status.get("base") is True and "error" not in status and status.get("version", 0) not in (0, 255)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("port", nargs="?", help="the robot's USB serial port (default: the only cu.usbmodem*)")
    parser.add_argument("--cycles", type=int, default=3, help="sleep and wake this many times (default 3)")
    args = parser.parse_args()

    if stanbot_running():
        print("Stanbot is open. Quit it first: it may start a session under this check.", file=sys.stderr)
        return 2
    port = args.port
    if not port:
        ports = glob.glob("/dev/cu.usbmodem*")
        if len(ports) != 1:
            print(f"Expected one USB serial port, found {ports}. Name it.", file=sys.stderr)
            return 2
        port = ports[0]

    before = base_status(port)
    print(f"before: {before}")
    if not healthy(before):
        print("FAIL: the head cannot reach its base even before sleeping. Reboot the robot and try again.")
        return 1
    for cycle in range(args.cycles):
        exchange(port, "C,SLEEP", 2.5)   # long enough for the eyes to close and the backlight to go
        exchange(port, "C,WAKE", 2.5)
        print(f"  slept and woke ({cycle + 1}/{args.cycles})")
    after = base_status(port)
    print(f"after:  {after}")
    if not healthy(after):
        print(f"FAIL: after {args.cycles} sleep/wake cycles the head cannot reach its base.\n"
              "      Something in sleep or wake is breaking the internal I2C bus; see\n"
              "      firmware/camera_stream/backlight.h and companion/test_i2c_ownership.py.")
        return 1
    print(f"PASS: the base still answers after {args.cycles} sleep/wake cycles.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
