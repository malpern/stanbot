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


def test_command_waits_for_its_own_answer():
    """A result from a PREVIOUS command must never be read as this one's."""
    with tempfile.TemporaryDirectory() as tmp:
        request = os.path.join(tmp, "command.json")
        result = os.path.join(tmp, "command-result.json")

        # An old result is already lying there, as it always will be in practice.
        with open(result, "w") as f:
            json.dump({"id": "an-older-one", "ok": True, "detail": "stale"}, f)

        ok, detail = cli.command("sleep", timeout=0.6, request_path=request, result_path=result,
                                 allow_usb=False)
        assert ok is False, "took a stale result as its own answer"
        assert "did not answer" in detail, detail

        # The request itself was written, and is well formed.
        with open(request) as f:
            written = json.load(f)
        assert written["command"] == "sleep" and written["id"], written
        assert "argument" not in written, "no argument should mean no key"

        # Now answer it properly.
        with open(result, "w") as f:
            json.dump({"id": written["id"], "ok": True, "detail": "asked the robot to sleep"}, f)
        ok, detail = cli.command("sleep", timeout=0.6, request_path=request, result_path=result,
                                 allow_usb=False)
        # A fresh id is minted each call, so the answer above is stale for it too.
        assert ok is False, "ids must be unique per call"


def test_command_carries_its_argument():
    with tempfile.TemporaryDirectory() as tmp:
        request = os.path.join(tmp, "command.json")
        cli.command("mouth", "grille", timeout=0.2, request_path=request,
                    result_path=os.path.join(tmp, "none.json"), allow_usb=False)
        with open(request) as f:
            written = json.load(f)
        assert written["command"] == "mouth" and written["argument"] == "grille", written


def test_the_route_depends_on_whether_the_app_is_running():
    """With Stanbot closed there is nothing holding the port, so USB is both
    correct and the only thing that can work. The first version of this only
    knew the app and quietly timed out whenever Stanbot was closed."""
    took = []
    cli.command_over_usb = lambda verb, argument=None: (took.append((verb, argument)) or (True, "usb"))

    cli.app_is_running = lambda: False
    ok, detail = cli.command("sleep")
    assert ok and detail == "usb", (ok, detail)
    assert took == [("sleep", None)], took

    # With the app up, the app gets it -- a second reader on the port would
    # fight it for every reply.
    took.clear()
    cli.app_is_running = lambda: True
    with tempfile.TemporaryDirectory() as tmp:
        ok, detail = cli.command("sleep", timeout=0.3,
                                 request_path=os.path.join(tmp, "c.json"),
                                 result_path=os.path.join(tmp, "r.json"))
    assert took == [], "went to USB while the app was running"
    assert ok is False and "though it is running" in detail, detail


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
    test_command_waits_for_its_own_answer()
    test_command_carries_its_argument()
    test_the_route_depends_on_whether_the_app_is_running()
    print("stanbot cli: all checks passed")


if __name__ == "__main__":
    main()
