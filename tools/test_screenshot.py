#!/usr/bin/env python3
"""Checks for tools/screenshot.py that need no robot.

The packet parser is the part worth pinning: a screenshot shares the channel
with text replies and camera frames, so it almost never arrives alone or
aligned, and getting that wrong looks exactly like a robot that did not answer.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import screenshot


def packet(payload, magic=b"SBSS"):
    return magic + bytes([1]) + struct.pack("<I", 7) + struct.pack("<I", len(payload)) + payload


def test_finds_a_whole_packet():
    assert screenshot.extract(packet(b"\xff\xd8jpeg")) == b"\xff\xd8jpeg"


def test_waits_for_the_rest():
    whole = packet(b"0123456789")
    for cut in range(len(whole) - 1):
        assert screenshot.extract(whole[:cut]) is None, "claimed a partial packet at %d" % cut
    assert screenshot.extract(whole) == b"0123456789"


def test_ignores_what_shares_the_channel():
    noise = b'SBVR {"sketch":"camera_stream"}\nSBST {"mouth_packets":0}\n'
    frame = b"SBFR" + bytes([1]) + struct.pack("<I", 3) + struct.pack("<I", 4) + b"\xff\xd8\xff\xe0"
    buffer = noise + frame + b"trailing text\n" + packet(b"the picture")
    assert screenshot.extract(buffer) == b"the picture"


def test_a_false_header_inside_a_payload_does_not_derail_it():
    # "SBSS" can occur inside JPEG data. A length that cannot be real means
    # this was not a header, and the scan must continue rather than give up.
    buffer = b"SBSS" + bytes([1]) + struct.pack("<I", 1) + struct.pack("<I", 0xFFFFFFFF)
    buffer += packet(b"real one")
    assert screenshot.extract(buffer) == b"real one"

    zero = b"SBSS" + bytes([1]) + struct.pack("<I", 1) + struct.pack("<I", 0) + packet(b"after a zero")
    assert screenshot.extract(zero) == b"after a zero"


def test_oversize_is_refused_rather_than_buffered_forever():
    over = struct.pack("<I", screenshot.MAX_BYTES + 1)
    buffer = b"SBSS" + bytes([1]) + struct.pack("<I", 1) + over + b"x" * 100
    assert screenshot.extract(buffer) is None


def main():
    test_finds_a_whole_packet()
    test_waits_for_the_rest()
    test_ignores_what_shares_the_channel()
    test_a_false_header_inside_a_payload_does_not_derail_it()
    test_oversize_is_refused_rather_than_buffered_forever()
    print("tools/test_screenshot.py: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
