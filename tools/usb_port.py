#!/usr/bin/env python3
"""Talking to the robot over USB, correctly: DTR, and who else holds the port.

Two separate faults made USB checks report a healthy robot as broken, and both
looked like the robot's fault rather than the tool's.

**DTR must be asserted.** The ESP32-S3's USB CDC only delivers what the host
writes once the host raises DTR. `os.open` does not: a plain open leaves DTR
low, so every command written is silently swallowed and the robot answers
nothing at all. It reads exactly like a robot that has stopped listening.
Verified 2026-09-18 -- with DTR raised, `V` answered instantly; without it,
nothing, on the same cable and the same firmware.

**A second reader steals the replies.** `/dev/cu.*` can be opened by several
processes at once, and they do not share: bytes go to whichever read wins. So
while Stanbot holds the port, a check here can send a perfectly good command,
the robot can answer perfectly well, and this process sees silence. That is
what produced the "no SBST" failures on 2026-09-17 and a reboot that appeared
to vanish on 2026-09-18. It is not detectable from the silence itself, which is
why `holders()` asks the operating system instead of guessing.

Stdlib only, like the rest of `tools/`.
"""
import fcntl
import glob
import os
import select
import struct
import subprocess
import sys
import time

# <sys/ioccom.h>: TIOCMBIS sets the modem bits named in the argument.
TIOCMBIS = 0x8004746C
TIOCM_DTR = 0x002
TIOCM_RTS = 0x004


def find_port(explicit=None):
    """The robot's serial port, or (None, why). Either USB-C port may be the
    one that enumerates -- see docs/transport.md -- so this matches on the
    device name rather than assuming which end the cable is in."""
    if explicit:
        return explicit, None
    ports = glob.glob("/dev/cu.usbmodem*")
    if not ports:
        return None, "no /dev/cu.usbmodem* -- the robot is not on USB, or only its power is."
    if len(ports) > 1:
        return None, "several USB serial ports (%s). Name the one to use." % ", ".join(ports)
    return ports[0], None


def open_port(path):
    """Open the port with DTR and RTS raised, and drop whatever was buffered.

    Without the ioctl the robot never sees a byte of what follows.
    """
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        fcntl.ioctl(fd, TIOCMBIS, struct.pack("I", TIOCM_DTR | TIOCM_RTS))
    except OSError:
        os.close(fd)
        raise
    # The line settles after DTR comes up; anything already queued belongs to
    # whatever ran before us, and reading it as our own reply is a wrong answer.
    time.sleep(0.2)
    drain(fd)
    return fd


def drain(fd, quiet_for=0.25, limit=3.0):
    """Read until the robot has been silent for `quiet_for`, or `limit` passes.

    A single pass is not enough and the difference is not cosmetic: one pass
    left half of a previous screenshot in the buffer, and the next request
    found that packet and returned it as though it were fresh -- so a change
    that had worked looked as though it had not. A stale answer delivered
    confidently is worse than no answer. Found 2026-09-18.
    """
    give_up = time.time() + limit
    silent_since = None
    while time.time() < give_up:
        try:
            chunk = os.read(fd, 65536)
        except (BlockingIOError, OSError):
            chunk = b""
        if chunk:
            silent_since = None
            continue
        now = time.time()
        if silent_since is None:
            silent_since = now
        elif now - silent_since >= quiet_for:
            return True
        time.sleep(0.02)
    return False


def holders(path):
    """The other processes with this port open: [(pid, name)]. Empty when we
    are alone; empty too if `lsof` is unavailable, which is why callers treat
    this as corroboration for a failure and never as proof of success."""
    try:
        done = subprocess.run(["lsof", "-F", "pcn", "--", path],
                              capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return []
    found, pid, name = [], None, None
    for line in done.stdout.splitlines():
        if line.startswith("p"):
            if pid is not None and pid != os.getpid():
                found.append((pid, name))
            pid, name = int(line[1:]), None
        elif line.startswith("c"):
            name = line[1:]
    if pid is not None and pid != os.getpid():
        found.append((pid, name))
    return found


def contention_note(path):
    """One line naming who else has the port, or None. This is the difference
    between "the robot is broken" and "something else is reading its replies"
    -- the two are indistinguishable from the silence alone."""
    others = holders(path)
    if not others:
        return None
    who = ", ".join("%s (pid %d)" % (name or "?", pid) for pid, name in others)
    return ("%s is also holding %s. Replies go to whichever reader wins, so this "
            "check can see silence from a robot that is answering normally. "
            "Quit it and run this again." % (who, path))


def exchange(path, command, seconds, fd=None):
    """Send one command and return what the robot says for `seconds`.

    Pass `fd` to keep one open port across several exchanges; otherwise this
    opens and closes its own. Re-opening is not free of consequence on some
    boards -- raising DTR can reset them -- so a caller doing a sequence should
    hold one fd.
    """
    own = fd is None
    if own:
        fd = open_port(path)
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
        if own:
            os.close(fd)


def resolve_or_exit(explicit=None, stream=sys.stderr):
    """find_port, but printing the reason and exiting 2 the way the tools do."""
    path, why = find_port(explicit)
    if path is None:
        print(why, file=stream)
        raise SystemExit(2)
    return path
