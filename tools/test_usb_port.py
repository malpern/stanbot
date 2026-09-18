#!/usr/bin/env python3
"""Checks for tools/usb_port.py that need no robot.

The two things worth pinning are the ones that were wrong in the field: that
opening a port raises DTR (checked by capturing the ioctl, since there is no
robot here), and that a busy port is reported as busy rather than as silence.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import usb_port


def test_find_port():
    assert usb_port.find_port("/dev/cu.named") == ("/dev/cu.named", None)

    usb_port.glob.glob = lambda pattern: []
    path, why = usb_port.find_port()
    assert path is None and "not on USB" in why, why

    usb_port.glob.glob = lambda pattern: ["/dev/cu.usbmodemA", "/dev/cu.usbmodemB"]
    path, why = usb_port.find_port()
    assert path is None and "Name the one" in why, why

    usb_port.glob.glob = lambda pattern: ["/dev/cu.usbmodem31201"]
    assert usb_port.find_port() == ("/dev/cu.usbmodem31201", None)


def test_open_port_raises_dtr():
    """The whole point: a port opened without DTR swallows every command."""
    calls = []

    usb_port.os.open = lambda path, flags: 77
    usb_port.os.read = lambda fd, n: b""
    usb_port.time.sleep = lambda seconds: None
    usb_port.fcntl.ioctl = lambda fd, request, arg: calls.append((fd, request, arg))

    assert usb_port.open_port("/dev/cu.usbmodem31201") == 77
    assert len(calls) == 1, calls
    fd, request, arg = calls[0]
    assert fd == 77
    assert request == usb_port.TIOCMBIS, hex(request)
    bits = struct.unpack("I", arg)[0]
    assert bits & usb_port.TIOCM_DTR, "DTR not set -- the robot will receive nothing"
    assert bits & usb_port.TIOCM_RTS, "RTS not set"


def test_drain_waits_for_real_silence():
    """One quiet read is not silence: a packet still arriving would be left
    behind, and the next request would return it as a fresh answer."""
    # Chatter, a gap shorter than quiet_for, more chatter, then real silence.
    reads = [b"xx", b"", b"yy"] + [b""] * 20
    got = []
    clock = [0.0]
    real_time = usb_port.time.time
    usb_port.time.time = lambda: clock[0]
    usb_port.time.sleep = lambda s: None

    def stepping_read(fd, n):
        clock[0] += 0.05          # each read costs a little time
        chunk = reads.pop(0) if reads else b""
        if chunk:
            got.append(chunk)
        return chunk

    usb_port.os.read = stepping_read
    try:
        assert usb_port.drain(77) is True, "drain gave up while the line was quiet"
        # The point: it did not stop at the first empty read and miss "yy".
        assert got == [b"xx", b"yy"], got
    finally:
        usb_port.time.time = real_time


def test_drain_gives_up_on_a_line_that_never_stops():
    """A robot streaming flat out must not hang the tool forever."""
    clock = [0.0]
    real_time = usb_port.time.time
    usb_port.time.time = lambda: clock[0]
    usb_port.time.sleep = lambda s: None

    def noisy(fd, n):
        clock[0] += 0.05
        return b"frame data"

    usb_port.os.read = noisy
    try:
        assert usb_port.drain(77) is False, "drain should report it never went quiet"
    finally:
        usb_port.time.time = real_time


def test_send_line_does_not_leave_before_the_bytes_do():
    """Closing straight after the write loses the command outright."""
    order = []
    usb_port.time.sleep = lambda s: None
    clock = [0.0]
    real_time = usb_port.time.time
    usb_port.time.time = lambda: clock[0]
    usb_port.os.write = lambda fd, data: (order.append("write") or len(data))

    def read(fd, n):
        clock[0] += 0.05
        order.append("read")
        return b""

    usb_port.os.read = read
    try:
        ok, why = usb_port.send_line(77, "E,trouble")
        assert ok and why is None, why
        # It read AFTER writing: that is what drains the line and gives the CDC
        # time to finish before the caller closes the descriptor.
        assert order[0] == "write" and "read" in order[1:], order
    finally:
        usb_port.time.time = real_time


def test_send_line_reports_a_short_write():
    usb_port.os.write = lambda fd, data: len(data) - 1
    ok, why = usb_port.send_line(77, "E,sad")
    assert ok is False and "reached the robot" in why, why


def test_holders_parses_lsof():
    class Done:
        stdout = "p4242\ncStanbot\nn/dev/cu.usbmodem31201\np%d\ncpython3\n" % os.getpid()

    usb_port.subprocess.run = lambda *a, **k: Done()
    found = usb_port.holders("/dev/cu.usbmodem31201")
    # Our own process is not contention; the other one is.
    assert found == [(4242, "Stanbot")], found

    note = usb_port.contention_note("/dev/cu.usbmodem31201")
    assert "Stanbot" in note and "pid 4242" in note, note
    assert "whichever reader wins" in note, note


def test_no_holders_and_no_lsof_are_both_quiet():
    class Empty:
        stdout = ""

    usb_port.subprocess.run = lambda *a, **k: Empty()
    assert usb_port.holders("/dev/x") == []
    assert usb_port.contention_note("/dev/x") is None

    # lsof missing must not crash a check that is only corroborating a failure.
    def boom(*a, **k):
        raise OSError("no lsof")

    usb_port.subprocess.run = boom
    assert usb_port.holders("/dev/x") == []
    assert usb_port.contention_note("/dev/x") is None


def main():
    test_find_port()
    test_open_port_raises_dtr()
    test_drain_waits_for_real_silence()
    test_drain_gives_up_on_a_line_that_never_stops()
    test_send_line_does_not_leave_before_the_bytes_do()
    test_send_line_reports_a_short_write()
    test_holders_parses_lsof()
    test_no_holders_and_no_lsof_are_both_quiet()
    print("tools/test_usb_port.py: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
