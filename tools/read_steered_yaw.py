#!/usr/bin/env python3
"""Read the head position the owner steered to, out of a session log.

    python3 tools/read_steered_yaw.py                  # the newest session log
    python3 tools/read_steered_yaw.py LOG [--centre 460]

Calibration by eye works like this: the owner turns Follow on, steers the head
with the direction pad or the arrow keys until it looks right to them, and lets
go. The head then holds still for 1.5 s before following resumes and pulls it
away again, so the answer is the LAST run of manual-mode samples in the log,
and within it the trailing samples whose position has stopped changing.

This prints that position: raw yaw and pitch, how long it was held, and how far
the yaw is from the centre the firmware currently believes in. It refuses to
answer when the head was still moving when the log ends, because a reading
taken mid-turn is a wrong answer that looks like a right one. Stdlib only.
"""
import argparse
import glob
import json
import os
import sys

LOG_DIR = os.path.expanduser("~/Library/Logs/Stanbot")
MANUAL = 4               # FollowMode::Manual, head_tracker.h
YAW_RAW_PER_DEG = 3.2    # 288 raw swept 90 degrees, 2026-09-15
PITCH_RAW_PER_DEG = 3.0  # 271 raw from level to vertical, 2026-09-17


def newest_log(directory=LOG_DIR):
    logs = sorted(glob.glob(os.path.join(directory, "follow-*.log")))
    return logs[-1] if logs else None


def traces(lines):
    """Every SBPD follow_trace sample, in order."""
    out = []
    for raw in lines:
        tag, _, body = raw.strip().partition(" ")
        if tag != "SBPD" or not body.startswith("{"):
            continue
        try:
            data = json.loads(body)
        except ValueError:
            continue
        if data.get("phase") == "follow_trace":
            out.append(data)
    return out


def last_manual_run(samples):
    """The last contiguous run of manual-mode samples, or []."""
    end = None
    for i in range(len(samples) - 1, -1, -1):
        if samples[i].get("mode") == MANUAL:
            end = i
            break
    if end is None:
        return []
    start = end
    while start > 0 and samples[start - 1].get("mode") == MANUAL:
        start -= 1
    return samples[start:end + 1]


def held(run):
    """The trailing samples of a manual run whose yaw and pitch stopped moving."""
    if not run:
        return []
    last = run[-1]
    i = len(run) - 1
    while i > 0 and run[i - 1].get("yaw") == last.get("yaw") and run[i - 1].get("pitch") == last.get("pitch"):
        i -= 1
    return run[i:]


def reading(lines, centre=460):
    """What the steered head settled on, or why there is no answer."""
    run = last_manual_run(traces(lines))
    if not run:
        return {"ok": False, "why": "no manual steering in this log"}
    rest = held(run)
    held_ms = rest[-1]["elapsed_ms"] - rest[0]["elapsed_ms"]
    answer = {
        "ok": len(rest) >= 2,
        "yaw": rest[-1]["yaw"],
        "pitch": rest[-1]["pitch"],
        "yaw_goal": rest[-1].get("yaw_goal"),
        "held_ms": held_ms,
        "held_samples": len(rest),
        "steps": len(run),
        "offset_from_centre": rest[-1]["yaw"] - centre,
        "offset_deg": round((rest[-1]["yaw"] - centre) / YAW_RAW_PER_DEG, 1),
    }
    if not answer["ok"]:
        answer["why"] = "the head was still moving when the log ended: hold it still, then read again"
    return answer


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="?", help="session log (default: the newest one)")
    ap.add_argument("--centre", type=int, default=460, help="the yaw centre the firmware believes in")
    ap.add_argument("--json", action="store_true", help="print the reading as JSON")
    args = ap.parse_args(argv)

    log = args.log or newest_log()
    if not log or not os.path.exists(log):
        print("no session log found", file=sys.stderr)
        return 1
    with open(log) as f:
        answer = reading(f.readlines(), args.centre)

    if args.json:
        print(json.dumps(answer))
        return 0 if answer["ok"] else 1
    print(f"log: {log}")
    if "why" in answer and not answer["ok"] and "yaw" not in answer:
        print(answer["why"])
        return 1
    print(f"steered to yaw {answer['yaw']}, pitch {answer['pitch']} "
          f"(held {answer['held_ms']} ms over {answer['held_samples']} samples, {answer['steps']} steering samples)")
    print(f"yaw is {answer['offset_from_centre']:+d} raw ({answer['offset_deg']:+.1f} deg) from centre {args.centre}")
    if not answer["ok"]:
        print(answer["why"])
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
