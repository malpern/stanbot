#!/usr/bin/env python3
"""Hardware check: does the robot accept mouth packets?

The mouth has never been seen on the robot. Seeing it needs an eye on its face;
this checks everything up to the drawing -- that packets arrive, pass the
robot's checks, and are counted rather than rejected -- which is the part that
fails silently. It makes no sound: it sends the datagrams the app would send
while speaking, without playing anything.

    python3 tools/check_mouth.py                 # finds the port and the robot
    python3 tools/check_mouth.py --host 192.168.1.241

Reads `SBST` over USB before and after. Exit 0: every packet was accepted.
Exit 1: some were rejected, or none arrived.

Packets are accepted only from the robot's current Wi-Fi viewer's address, so
this must run on the Mac the app is connected from -- which is the same Mac,
and why it works without touching the app.
"""
import argparse
import glob
import json
import math
import os
import select
import socket
import struct
import sys
import time

MOUTH_PORT = 3334


def exchange(port, command, seconds):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
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
        os.close(fd)


def stats(port):
    """The SBST line, or None. Stops the stream first: text and frames share
    this channel and a reply among JPEG data is shredded (check_sleep_wake.py
    learned that the hard way)."""
    exchange(port, "X", 1)
    for line in exchange(port, "P", 3).splitlines():
        if line.startswith("SBST ") and '"mouth_packets"' in line:
            try:
                return json.loads(line[5:])
            except json.JSONDecodeError:
                return None
    return None


def packet(sequence, opening, shape):
    """"SBMO", version 2, opening 0-100, shape -100..100, sequence u32 LE."""
    return struct.pack("<4sBBbI", b"SBMO", 2, opening, shape, sequence)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="stanbot.local")
    parser.add_argument("--port", help="USB serial port (default: the only cu.usbmodem*)")
    parser.add_argument("--seconds", type=float, default=3.0)
    args = parser.parse_args(argv)

    serial_port = args.port
    if not serial_port:
        ports = glob.glob("/dev/cu.usbmodem*")
        if len(ports) != 1:
            print(f"Expected one USB serial port, found {ports}. Name it.", file=sys.stderr)
            return 2
        serial_port = ports[0]

    before = stats(serial_port)
    if before is None:
        print("no SBST from the robot: is it on USB?", file=sys.stderr)
        return 2
    print(f"before: mouth_packets={before['mouth_packets']} mouth_rejected={before['mouth_rejected']}")

    # A plausible mouth: a sentence's worth of opening and shaping at the app's
    # cadence, so this exercises the same rate the real thing will.
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sent = 0
    start = time.time()
    while time.time() - start < args.seconds:
        phase = (time.time() - start) * 3.0
        opening = int(50 + 45 * math.sin(phase))
        shape = int(60 * math.sin(phase * 0.7))
        sock.sendto(packet(sent + 1, max(0, min(100, opening)), max(-100, min(100, shape))),
                    (args.host, MOUTH_PORT))
        sent += 1
        time.sleep(0.05)   # 20 Hz, as the app sends while speaking
    sock.sendto(packet(sent + 1, 0, 0), (args.host, MOUTH_PORT))   # the closing 0
    sent += 1
    time.sleep(0.5)

    # The app re-enables the stream whenever it reconnects, and text arriving
    # among JPEG frames is shredded, so one read can come back empty while the
    # robot is perfectly well. Try a few times before calling it a failure --
    # on 2026-09-17 a run that had actually delivered every packet reported "no
    # SBST" and looked like a fault.
    after = None
    for _ in range(3):
        after = stats(serial_port)
        if after is not None:
            break
    if after is None:
        print("could not read SBST back. The packets may still have arrived: "
              "watch the robot, or quit Stanbot and try again.", file=sys.stderr)
        return 2
    accepted = after["mouth_packets"] - before["mouth_packets"]
    rejected = after["mouth_rejected"] - before["mouth_rejected"]
    print(f"after:  mouth_packets={after['mouth_packets']} mouth_rejected={after['mouth_rejected']}")
    print(f"sent {sent}, accepted {accepted}, rejected {rejected}")
    if accepted == 0:
        print("FAIL: the robot received none of them. Wrong host, or it is not the Wi-Fi viewer.")
        return 1
    if rejected:
        print("FAIL: some were rejected. The packet shape or the source address is wrong.")
        return 1
    print("PASS: the robot accepted every mouth packet. (Whether it DREW them still needs an eye.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
