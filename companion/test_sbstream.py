#!/usr/bin/env python3
"""Boundary tests for the stream demultiplexer.

The cases that matter are the ones that actually corrupted a follow session's
telemetry on 2026-09-15: payload that contains the packet magic, payload full
of newlines, and text arriving in the same read as binary.
"""
import sys

from sbstream import Demuxer, frame_packet, telemetry_check


def collect(chunks):
    demuxer = Demuxer()
    events = []
    for chunk in chunks:
        events.extend(demuxer.feed(chunk))
    return demuxer, events


def texts(events):
    return [value for kind, value in events if kind == "text"]


def frames(events):
    return [value for kind, value in events if kind == "frame"]


def test_plain_text():
    _, events = collect([b'SBMV {"result":"ok"}\n'])
    assert texts(events) == ['SBMV {"result":"ok"}']


def test_frame_alone():
    payload = b"\xff\xd8" + bytes(range(256)) * 4 + b"\xff\xd9"
    _, events = collect([frame_packet(7, payload)])
    assert frames(events) == [(7, payload)]


def test_payload_containing_magic_is_not_a_packet():
    # A JPEG that happens to contain SBFR must be delivered whole, not split.
    payload = b"\xff\xd8" + b"....SBFR...." + b"\xff\xd9"
    _, events = collect([frame_packet(1, payload)])
    assert frames(events) == [(1, payload)]
    assert texts(events) == []


def test_payload_containing_newlines_does_not_become_text():
    payload = b"\xff\xd8" + b"\n\n\nSBMV not really text\n\n" + b"\xff\xd9"
    _, events = collect([frame_packet(2, payload)])
    assert frames(events) == [(2, payload)]
    assert texts(events) == []


def test_text_between_frames_in_one_read():
    payload = b"\xff\xd8\xff\xd9"
    blob = (frame_packet(1, payload) + b'SBST {"sent":1}\n' +
            frame_packet(2, payload) + b'SBWF {"profiles":3}\n')
    _, events = collect([blob])
    assert [s for s, _ in frames(events)] == [1, 2]
    assert texts(events) == ['SBST {"sent":1}', 'SBWF {"profiles":3}']


def test_split_across_reads_byte_by_byte():
    payload = bytes(range(64))
    blob = b'SBPW {"a":1}\n' + frame_packet(9, payload) + b'SBMV {"b":2}\n'
    _, events = collect([blob[i:i + 1] for i in range(len(blob))])
    assert frames(events) == [(9, payload)]
    assert texts(events) == ['SBPW {"a":1}', 'SBMV {"b":2}']


def test_header_split_across_reads():
    payload = b"abcd" * 10
    packet = frame_packet(3, payload)
    _, events = collect([packet[:6], packet[6:11], packet[11:]])
    assert frames(events) == [(3, payload)]


def test_implausible_header_is_skipped_not_trusted():
    # Magic with a nonsense length must not swallow the stream; the real text
    # after it still arrives.
    import struct
    noise = b"SBFR" + struct.pack("<BII", 9, 0, 99999999)
    _, events = collect([noise + b'SBMV {"result":"ok"}\n'])
    assert texts(events) == ['SBMV {"result":"ok"}']


def test_attaching_mid_payload_recovers():
    # Start reading halfway through a frame, as a host that reconnects does.
    payload = b"\xff\xd8" + bytes(range(256)) * 8 + b"\xff\xd9"
    stream = frame_packet(4, payload) + b'SBMV {"result":"recovered"}\n'
    demuxer, events = collect([stream[500:]])
    assert 'SBMV {"result":"recovered"}' in texts(events)
    assert demuxer.dropped > 0        # the truncated payload was not silently kept


def test_telemetry_markers_make_newlines_authoritative():
    # Between SBTB and SBTE the firmware has stopped the stream, so a line that
    # contains the magic is still just a line.
    blob = (b'SBTB {"telemetry":"begin","plan":"follow"}\n'
            b'SBPD {"phase":"follow_trace","note":"SBFR appears here"}\n'
            b'SBTE {"telemetry":"end"}\n')
    _, events = collect([blob])
    assert texts(events) == [
        'SBTB {"telemetry":"begin","plan":"follow"}',
        'SBPD {"phase":"follow_trace","note":"SBFR appears here"}',
        'SBTE {"telemetry":"end"}',
    ]
    assert frames(events) == []


def test_frames_resume_after_telemetry_block():
    payload = b"\xff\xd8\xff\xd9"
    blob = (b'SBTB {"telemetry":"begin"}\n' + b'SBTE {"telemetry":"end"}\n' +
            frame_packet(5, payload))
    _, events = collect([blob])
    assert frames(events) == [(5, payload)]


def test_the_exact_corruption_seen_on_hardware():
    # A text line cut mid-word by a packet, which is what arrived on
    # 2026-09-15 and made a session's results unreadable.
    payload = b"\xff\xd8\xff\xe0\x00\x10JFIF" + b"\x00" * 32
    blob = b'SBPD {"phase":"follo' + frame_packet(6, payload)
    demuxer, events = collect([blob])
    # The truncated line is not reported as if it were complete and valid.
    assert texts(events) == [] or all("follo\"" not in t for t in texts(events))
    assert frames(events) == [(6, payload)]
    assert demuxer.dropped > 0


def test_telemetry_check_matches_firmware_vector():
    block = ['SBMV {"result":"session_idle"}', 'SBFL {"renewals":3}']
    end = 'SBTE {"telemetry":"end","lines":2,"crc32":"76f85edc"}'
    assert telemetry_check(block, end) == "verified"
    assert telemetry_check([b + "\r" for b in block], end) == "verified"
    assert telemetry_check(['SBMV {"result":"session_idl"}', block[1]], end) == "corrupted"
    assert telemetry_check([block[0] + block[1]], end) == "corrupted"
    assert telemetry_check(block, 'SBTE {"telemetry":"end"}') == "unchecked"


def main():
    tests = [value for name, value in sorted(globals().items())
             if name.startswith("test_") and callable(value)]
    for test in tests:
        test()
    print(f"sbstream: {len(tests)} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
