#!/usr/bin/env python3
"""Checks for tools/stanbot against synthetic status files."""
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import time

spec = importlib.util.spec_from_loader(
    "stanbot_cli", importlib.machinery.SourceFileLoader(
        "stanbot_cli", os.path.join(os.path.dirname(os.path.abspath(__file__)), "stanbot")))
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)

FRESH = {
    "connection": "Wi-Fi control connected", "connected": True,
    "camera": "Live · local only", "face": "tracking", "asleep": False,
    "last_action": "Head following: session finished",
    "firmware": {"commit": "95ff481", "yaw_range": 288, "pitch": True, "scan_pending": False},
    "follow": {"toggle": True, "state": "idle", "unavailable_reason": None},
    "last_seen": {"yaw": 512, "pitch": 630},
}


def main():
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "status.json")

        # No file at all is a clear answer, not a crash.
        status, why = cli.read(path)
        assert status is None and "no status file" in why, why
        assert cli.main(["status", "--path", path]) == 1

        with open(path, "w") as f:
            json.dump(FRESH, f)
        status, age = cli.read(path)
        assert status is not None and age < 5
        report = cli.describe(status, age)
        assert "toggle ON" in report, report
        assert "yaw +-288" in report and "pitch" in report
        assert "yaw 512, pitch 630" in report
        assert "STALE" not in report
        assert cli.main(["status", "--path", path]) == 0
        assert cli.main(["status", "--json", "--path", path]) == 0

        # The reason a session cannot start is the thing most often wanted.
        blocked = json.loads(json.dumps(FRESH))
        blocked["follow"] = {"toggle": False, "state": "idle",
                             "unavailable_reason": "Needs the camera stream, to find a face."}
        assert "toggle OFF" in cli.describe(blocked, 1)
        assert "cannot start: Needs the camera stream" in cli.describe(blocked, 1)

        # Nothing remembered yet must say so rather than printing nothing.
        blank = json.loads(json.dumps(FRESH))
        del blank["last_seen"]
        assert "nowhere yet" in cli.describe(blank, 1)

        # A stale file is the dangerous case: a plausible report from a dead app.
        # It must say so, and exit nonzero.
        old = time.time() - 3600
        os.utime(path, (old, old))
        status, age = cli.read(path)
        assert "STALE" in cli.describe(status, age)
        assert cli.main(["status", "--path", path]) == 2

        # Unparseable is not a crash either.
        with open(path, "w") as f:
            f.write("{ not json")
        status, why = cli.read(path)
        assert status is None and "unreadable" in why
    print("stanbot cli: all checks passed")


if __name__ == "__main__":
    main()
