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
import json
import math
import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import usb_port

MOUTH_PORT = 3334


def exchange(port, command, seconds):
    """`usb_port.exchange`: raises DTR, without which the robot receives nothing."""
    return usb_port.exchange(port, command, seconds)


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

    serial_port = usb_port.resolve_or_exit(args.port)
    # Unlike check_sleep_wake.py this cannot simply refuse when something else
    # holds the port: the robot only accepts mouth packets from its current
    # Wi-Fi viewer, so Stanbot has to be running. When Stanbot is also on USB it
    # takes the SBST replies and this check goes blind -- so say which it is,
    # rather than blaming the robot for a silence it did not cause.
    contention = usb_port.contention_note(serial_port)

    before = stats(serial_port)
    if before is None:
        print("no SBST from the robot.", file=sys.stderr)
        print(contention or "Nothing else holds the port, so this is the robot or the cable.",
              file=sys.stderr)
        if contention:
            print("Put Stanbot on Wi-Fi (it only needs USB for the camera) and run this again.",
                  file=sys.stderr)
        return 2
    print(f"before: mouth_packets={before['mouth_packets']} mouth_rejected={before['mouth_rejected']}")

    # A plausible mouth: a sentence's worth of opening and shaping at the app's
    # cadence, so this exercises the same rate the real thing will.
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sent = 0
    start = time.time()
    try:
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
    except OSError as error:
        # A traceback here reads as a broken tool. It is usually the network:
        # the name not resolving, or macOS's Local Network privacy refusing the
        # LAN from this shell (see the note in ACCESS.md). Say which host.
        print(f"cannot reach {args.host}:{MOUTH_PORT} -- {error}", file=sys.stderr)
        print("The robot's USB side answered, so this is the network, not the robot.\n"
              "Pass --host with the robot's address, and check this shell is allowed\n"
              "on the local network.", file=sys.stderr)
        return 2
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
        print("could not read SBST back. The packets may still have arrived.", file=sys.stderr)
        print(contention or "Nothing else holds the port: watch the robot, or try again.",
              file=sys.stderr)
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
