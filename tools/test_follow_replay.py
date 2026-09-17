#!/usr/bin/env python3
"""Checks for follow_replay.py against a small synthetic session log."""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import follow_replay  # noqa: E402

LOG = """APP {"t":100.000,"faces":1,"detections":[[0.750,0.500,0.2,0.2,0.9]],"state":"tracking","sent":1,"x":0.500,"y":0.000}
APP {"t":100.200,"faces":0,"detections":[],"state":"uncertain"}
SBTB {"telemetry":"begin","plan":"follow"}\r
SBPD {"phase":"follow_trace","elapsed_ms":0,"yaw_goal":460,"yaw":460,"pitch_goal":620,"pitch":620,"mode":0}
SBPD {"phase":"follow_trace","elapsed_ms":100,"yaw_goal":470,"yaw":466,"pitch_goal":620,"pitch":620,"mode":1}
SBPD {"phase":"follow_trace","elapsed_ms":200,"yaw_goal":480,"yaw":478,"pitch_goal":620,"pitch":620,"mode":1}
SBPD {"phase":"follow_trace","elapsed_ms":300,"yaw_goal":470,"yaw":471,"pitch_goal":620,"pitch":620,"mode":3}
SBPD {"phase":"follow_trace","elapsed_ms":400,"yaw_goal":460,"yaw":461,"pitch_goal":620,"pitch":620,"mode":2}
SBMV {"result":"session_idle","plan":"follow","pitch_enabled":true,"observations":1,"rejected":0}
SBFL {"iterations":10,"renewals":0}
SBTE {"telemetry":"end","lines":7,"crc32":"00000000"}
"""


def main():
    session = follow_replay.parse(LOG.splitlines(keepends=True))
    summary = follow_replay.summarize(session)
    assert summary["trace_points"] == 5
    assert summary["frames"] == 2 and summary["frames_with_face"] == 1 and summary["targets_sent"] == 1
    assert summary["result"] == "session_idle"
    assert summary["yaw"]["range"] == [460, 478]
    assert summary["yaw"]["max_error"] == 4
    assert summary["yaw"]["reversals"] == 1              # up to 478, back down
    assert set(summary["mode_ms"]) == {"idle", "attending", "searching"}
    # The CRC in this synthetic SBTE is deliberately wrong.
    assert summary["telemetry"] == "corrupted"
    with tempfile.TemporaryDirectory() as tmp:
        log = os.path.join(tmp, "follow-test.log")
        with open(log, "w") as f:
            f.write(LOG)
        assert follow_replay.main([log]) == 0
        page = open(os.path.join(tmp, "follow-test.html")).read()
        assert "<svg" in page and "session_idle" in page and "arrived damaged" in page
    print("follow replay: all checks passed")


if __name__ == "__main__":
    main()
