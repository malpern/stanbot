#!/usr/bin/env python3
"""A picture of what is actually on the robot's screen.

Until this existed, the only way to check a change to the face was to stand in
front of the robot, which is why the docs carry a list of things "built, not yet
seen" -- the glance at a face, the wake scan, the mouth, the trouble face. The
robot composes its whole face into one sprite (`eyeFrame`); this asks for that
sprite back as a JPEG.

    python3 tools/screenshot.py                     # -> stanbot-screen.jpg
    python3 tools/screenshot.py --out /tmp/face.jpg
    python3 tools/screenshot.py --expression sad    # set it, then look

Exit 0 and a file on success. Exit 1 if the robot refused or said nothing;
exit 2 for a port that is missing or held by something else -- Stanbot takes
the replies if it is on USB, and a screenshot that silently never arrives is
exactly the debugging problem this exists to remove.
"""
import argparse
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import usb_port

MAGIC = b"SBSS"
HEADER = 13          # magic(4) version(1) sequence(u32) length(u32)
MAX_BYTES = 300000   # kMaxJpegBytes in the firmware


def grab(port, seconds=6.0, fd=None):
    """Ask for one screenshot; return (jpeg_bytes, note) or (None, why)."""
    own = fd is None
    if own:
        fd = usb_port.open_port(port)
    try:
        os.write(fd, b"C,SCREEN\n")
        deadline = time.time() + seconds
        buffer = b""
        while time.time() < deadline:
            try:
                chunk = os.read(fd, 65536)
            except (BlockingIOError, OSError):
                chunk = b""
            if not chunk:
                time.sleep(0.02)
                continue
            buffer += chunk
            found = extract(buffer)
            if found is not None:
                return found, None
            if b"SBSH" in buffer and b'"ok":false' in buffer:
                line = [l for l in buffer.split(b"\n") if b"SBSH" in l]
                return None, line[-1].decode("utf-8", "replace").strip()
        return None, "no screenshot arrived in %.0f s" % seconds
    finally:
        if own:
            os.close(fd)


def extract(buffer):
    """The JPEG out of an SBSS packet, or None if one is not complete yet.

    Scans rather than assuming the packet starts at byte 0: text replies and
    camera frames share this channel, so a screenshot rarely arrives alone.
    """
    start = 0
    while True:
        at = buffer.find(MAGIC, start)
        if at < 0 or len(buffer) < at + HEADER:
            return None
        length = struct.unpack_from("<I", buffer, at + 9)[0]
        if length == 0 or length > MAX_BYTES:
            start = at + 1           # not a real header; keep looking
            continue
        if len(buffer) < at + HEADER + length:
            return None              # still arriving
        return buffer[at + HEADER:at + HEADER + length]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="stanbot-screen.jpg")
    parser.add_argument("--port", help="USB serial port (default: the only cu.usbmodem*)")
    parser.add_argument("--expression", help="set this expression first (E,<name>), then look")
    parser.add_argument("--seconds", type=float, default=6.0)
    args = parser.parse_args(argv)

    port = usb_port.resolve_or_exit(args.port)
    contention = usb_port.contention_note(port)
    if contention:
        print(contention, file=sys.stderr)
        return 2

    fd = usb_port.open_port(port)
    try:
        # Frames would arrive in the middle of the screenshot and make finding
        # its header a lottery, so stop the stream first -- the same reason
        # check_mouth.py and check_sleep_wake.py do.
        os.write(fd, b"X\n")
        time.sleep(0.4)
        if args.expression:
            os.write(fd, ("E," + args.expression + "\n").encode())
            time.sleep(1.2)          # let the pose spring settle before looking
        jpeg, why = grab(port, args.seconds, fd=fd)
    finally:
        os.close(fd)

    if jpeg is None:
        print("no screenshot: %s" % why, file=sys.stderr)
        return 1
    with open(args.out, "wb") as f:
        f.write(jpeg)
    print("%s (%d bytes)" % (args.out, len(jpeg)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
