#!/usr/bin/env python3
"""Checks for read_steered_yaw.py against synthetic session logs."""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import read_steered_yaw  # noqa: E402


def trace(ms, yaw, pitch, mode):
    return ('SBPD {"phase":"follow_trace","elapsed_ms":%d,"yaw_goal":%d,"yaw":%d,'
            '"pitch_goal":%d,"pitch":%d,"mode":%d}\n' % (ms, yaw, yaw, pitch, pitch, mode))


# Following, then steering right, then a hold: the hold is the answer.
STEERED = (['APP {"t":1.0,"faces":0,"detections":[],"state":"searching"}\n',
            trace(0, 460, 614, 0), trace(100, 470, 614, 1), trace(200, 478, 614, 1)]
           + [trace(300, 482, 614, 4), trace(400, 486, 614, 4), trace(500, 490, 614, 4)]
           + [trace(600, 492, 614, 4), trace(940, 492, 614, 4), trace(1280, 492, 614, 4)])


def main():
    answer = read_steered_yaw.reading(STEERED)
    assert answer["ok"], answer
    assert answer["yaw"] == 492 and answer["pitch"] == 614, answer
    assert answer["held_ms"] == 680 and answer["held_samples"] == 3, answer
    assert answer["steps"] == 6, answer
    assert answer["offset_from_centre"] == 32 and answer["offset_deg"] == 10.0, answer

    # A different centre moves only the offset.
    assert read_steered_yaw.reading(STEERED, centre=492)["offset_from_centre"] == 0

    # Still moving when the log ends: no answer, and it says why.
    moving = STEERED[:-3] + [trace(600, 494, 614, 4)]
    answer = read_steered_yaw.reading(moving)
    assert not answer["ok"] and "still moving" in answer["why"], answer

    # A later manual run wins over an earlier one.
    twice = STEERED + [trace(3000, 450, 614, 1), trace(3100, 440, 614, 4),
                       trace(3200, 436, 614, 4), trace(3540, 436, 614, 4)]
    assert read_steered_yaw.reading(twice)["yaw"] == 436

    # No steering at all is not an answer either.
    answer = read_steered_yaw.reading([trace(0, 460, 614, 1)])
    assert not answer["ok"] and "no manual steering" in answer["why"], answer

    # Pitch moving on its own also counts as still moving.
    pitching = STEERED[:-1] + [trace(1280, 492, 618, 4)]
    assert not read_steered_yaw.reading(pitching)["ok"]

    with tempfile.TemporaryDirectory() as tmp:
        log = os.path.join(tmp, "follow-20260917-160000.log")
        with open(log, "w") as f:
            f.writelines(STEERED)
        assert read_steered_yaw.newest_log(tmp) == log
        assert read_steered_yaw.main([log]) == 0
        assert read_steered_yaw.main([log, "--json"]) == 0
    print("read_steered_yaw: all checks passed")


if __name__ == "__main__":
    main()
