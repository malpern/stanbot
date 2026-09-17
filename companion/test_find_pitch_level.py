#!/usr/bin/env python3
"""The bisection in find_pitch_level.py, without a robot."""
import os
import sys
import tempfile

import find_pitch_level as f


def simulate(level):
    """Answer like a person watching a head whose true level is `level`."""
    moves = []

    def run(cmd, check):
        if "--pitch-level" in cmd:
            moves.append(int(cmd[-1]))

    def ask(_prompt):
        raw = moves[-1]
        return "l" if abs(raw - level) <= 1 else ("u" if raw > level else "d")

    f.wait_for_port = lambda port, timeout=30: True
    with tempfile.TemporaryDirectory() as tmp:
        assert f.main(["/dev/null", "--record", os.path.join(tmp, "r.jsonl")], ask=ask, run=run) == 0
        records = open(os.path.join(tmp, "r.jsonl")).read().splitlines()
    assert all(f.LOW <= m <= f.HIGH for m in moves)
    assert len(records) == len(moves)
    return moves


def main():
    assert f.next_interval(596, 672, 634, "u") == (596, 633)
    assert f.next_interval(596, 672, 634, "d") == (635, 672)
    assert f.next_interval(596, 672, 634, "l") is None
    for level in (598, 601, 612, 620, 634, 650, 670):
        moves = simulate(level)
        assert len(moves) <= 7, (level, moves)
        assert abs(moves[-1] - level) <= 4, (level, moves)
    print("find pitch level: all checks passed")


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
