#!/usr/bin/env python3
"""Find the pitch raw position where StackChan's head looks level, by eye.

    python3 companion/find_pitch_level.py /dev/cu.usbmodemXXXX

Supervised, at the robot, over USB, with the Stanbot app closed. Checklist
step 2 (docs/head-following.md) needs a pitch rest confirmed by a person; no
sensor can say what "level" looks like. This bisects between 596 and 672:

  1. reboot the robot, for a fresh once-per-boot power window;
  2. move pitch to the midpoint and hold it 4 s (C,PITCHLEVEL via probe_servos);
  3. you answer: is the head tilted up (u), down (d), or level (l)?

+raw tilts up on this unit (measured 2026-09-15), so "up" searches lower
values. It stops when you say level or the interval is under 4 raw, and prints
what to record in head_tracker.h. It never writes the header itself: a person
confirms the value before it becomes the position a lost target returns to.
Each step is logged to --record (default: calibration-pitch-level.jsonl).
"""
import argparse
import datetime
import glob
import json
import subprocess
import sys
import time

LOW, HIGH = 596, 672
HERE = __file__.rsplit("/", 1)[0] or "."


def next_interval(low, high, raw, answer):
    """The interval left after `answer` at `raw`; None once level is found."""
    if answer == "l":
        return None
    if answer == "u":          # tilted up: level is at a lower raw value
        return low, raw - 1
    if answer == "d":
        return raw + 1, high
    raise ValueError(answer)


def wait_for_port(port, timeout=30):
    end = time.monotonic() + timeout
    time.sleep(2)
    while time.monotonic() < end:
        if glob.glob(port):
            time.sleep(1.5)
            return True
        time.sleep(0.5)
    return False


def main(argv=None, ask=input, run=subprocess.run):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("port")
    parser.add_argument("--record", default="calibration-pitch-level.jsonl")
    args = parser.parse_args(argv)
    # Stanbot must be closed. On 2026-09-17 it was open on Wi-Fi with automatic
    # following on: it started a session, the robot was busy powering the head
    # for that, never ran the level move or reported power off, and the probe
    # stopped with DISABLE LATCH NOT VERIFIED.
    if run is subprocess.run and subprocess.run(["pgrep", "-f", "Stanbot.app/Contents/MacOS/Stanbot"],
                                                capture_output=True).returncode == 0:
        print("Quit Stanbot first: it can start a follow session over Wi-Fi, and the robot "
              "cannot run the level move during one.")
        return 1
    low, high, found, steps = LOW, HIGH, None, 0
    while low <= high and high - low >= 4 and steps < 8:
        raw = (low + high) // 2
        steps += 1
        run([sys.executable, f"{HERE}/probe_servos.py", args.port, "--reboot"], check=True)
        if not wait_for_port(args.port):
            print("The robot did not come back on %s; stopping." % args.port)
            return 1
        print(f"\nStep {steps}: pitch to {raw}, held 4 s. Watch the head.")
        run([sys.executable, f"{HERE}/probe_servos.py", args.port, "--pitch-level", str(raw)], check=True)
        answer = ""
        while answer not in ("u", "d", "l", "q"):
            answer = ask("Tilted (u)p, (d)own, or (l)evel? (q to stop) ").strip().lower()[:1]
        with open(args.record, "a") as f:
            f.write(json.dumps({"at": datetime.datetime.now().isoformat(timespec="seconds"),
                                "raw": raw, "answer": answer}) + "\n")
        if answer == "q":
            return 1
        interval = next_interval(low, high, raw, answer)
        if interval is None:
            found = raw
            break
        low, high = interval
    if found is None:
        found = (low + high) // 2
        print(f"\nNarrowed to {low}..{high}; {found} is the best estimate (within a few raw).")
    print(f"""
Level looks like raw {found}. To use it, in firmware/camera_stream/head_tracker.h
set pitchRest (and pitchMin, if level is below 620) to {found} and
pitchRestConfirmed to true, then record the session in docs/head-following.md.""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
