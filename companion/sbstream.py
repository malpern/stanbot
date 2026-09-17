"""Demultiplex the robot's USB/TCP stream into frames and text lines.

The link carries two interleaved things: `SBFR` packets, which are binary and
carry their own length, and newline-terminated `SB__ {json}` text lines, which
do not. A reader that simply splits on newlines is wrong, because JPEG payload
contains newlines and can contain the bytes `SBFR` by chance; a reader that
simply hunts for `SBFR` is wrong too, because that magic appears inside payload.

The only correct reading is a state machine that, once it has a packet header,
skips exactly `length` bytes without looking inside them. That is what this is.

Recovering from a desync matters as much as avoiding one. A host that attaches
mid-stream, or reads bytes a previous session left buffered, starts in the
middle of a payload. So a packet header is accepted only when its version and
length are plausible, and the firmware brackets a follow session's telemetry
with `SBTB`/`SBTE` markers emitted while the stream is stopped: between those
two lines there are no packets, so the reader can trust newlines again whatever
happened before.
"""
import struct

MAGIC = b"SBFR"
HEADER = 13                # magic(4) + version(1) + sequence(4) + length(4)
MAX_JPEG = 300000          # the firmware's own bound; a bigger length is noise
TEXT_PREFIXES = (b"SBFR", b"SBFL", b"SBMV", b"SBPW", b"SBPD", b"SBSC", b"SBST",
                 b"SBWF", b"SBLG", b"SBOF", b"SBRB", b"SBTB", b"SBTE", b"SBVR", b"SBNR", b"SBCM", b"SBRG")


class Demuxer:
    """Feed bytes in, take (kind, value) events out.

    Events are ("frame", (sequence, jpeg_bytes)) and ("text", str).
    Bytes that belong to neither are dropped, and the count is kept so a caller
    can tell a clean link from one it is guessing at.
    """

    def __init__(self):
        self.buf = bytearray()
        self.dropped = 0
        self.in_telemetry = False

    def feed(self, data):
        self.buf.extend(data)
        return list(self._drain())

    def _plausible_header(self, at):
        if len(self.buf) - at < HEADER:
            return None
        version, sequence, length = struct.unpack_from("<BII", self.buf, at + 4)
        if version not in (1, 2) or length > MAX_JPEG:
            return None
        return sequence, length

    def _drain(self):
        while True:
            # Between the telemetry markers the firmware has stopped the
            # stream, so a newline is authoritative and magic in the text is
            # just text.
            if self.in_telemetry:
                newline = self.buf.find(b"\n")
                if newline < 0:
                    return
                line = bytes(self.buf[:newline])
                del self.buf[:newline + 1]
                text = line.decode("utf-8", "replace").strip()
                if text.startswith("SBTE"):
                    self.in_telemetry = False
                if text:
                    yield ("text", text)
                continue

            frame = self.buf.find(MAGIC)
            newline = self.buf.find(b"\n")

            if frame >= 0 and (newline < 0 or frame < newline):
                header = self._plausible_header(frame)
                if header is None:
                    if len(self.buf) - frame < HEADER:
                        # Header may still be arriving; emit any text in front
                        # of it and wait for the rest.
                        if frame:
                            yield from self._text(frame, terminated=False)
                            continue
                        return
                    # Magic with an implausible header is payload or noise.
                    self.dropped += 4
                    del self.buf[:frame + 4]
                    continue
                sequence, length = header
                if len(self.buf) - frame - HEADER < length:
                    return                      # payload still arriving
                if frame:
                    # Text ahead of a packet was cut off by it: whatever sits
                    # after the last newline never got one, so it is a lost
                    # line, not a short one.
                    yield from self._text(frame, terminated=False)
                    continue
                jpeg = bytes(self.buf[HEADER:HEADER + length])
                del self.buf[:HEADER + length]
                yield ("frame", (sequence, jpeg))
                continue

            if newline < 0:
                return
            yield from self._text(newline + 1)

    def _text(self, upto, terminated=True):
        """Take `upto` bytes as text, keeping only complete, recognised lines.

        A segment is searched, not merely inspected at its start: a reader that
        attached mid-payload sees binary immediately followed by a real line,
        with no newline between them, and that line is still worth having.

        `terminated` is false when the chunk ends because a packet began rather
        than because a newline did. The trailing segment is then an unfinished
        line, and reporting it as though it were complete is exactly how a
        shredded diagnostic gets mistaken for a real one.
        """
        chunk = bytes(self.buf[:upto])
        del self.buf[:upto]
        segments = chunk.split(b"\n")
        if not terminated and segments:
            self.dropped += len(segments[-1])
            segments = segments[:-1]
        for raw in segments:
            stripped = raw.strip()
            if not stripped:
                continue
            at = self._prefix_at(stripped)
            if at is None:
                self.dropped += len(raw)
                continue
            if at:
                self.dropped += at          # the binary that preceded the line
            text = stripped[at:].decode("utf-8", "replace")
            if text.startswith("SBTB"):
                # The firmware has stopped the stream for the telemetry block,
                # so stop hunting for packets until it says it is finished.
                self.in_telemetry = True
                yield ("text", text)
                return
            yield ("text", text)

    @staticmethod
    def _prefix_at(segment):
        """Offset of the first `SB__ ` tag in the segment, or None."""
        best = None
        for prefix in TEXT_PREFIXES:
            at = segment.find(prefix + b" ")
            if at >= 0 and (best is None or at < best):
                best = at
        return best


def telemetry_check(lines, end_line):
    """Verify a telemetry block against its SBTE line.

    `lines` are the text lines between SBTB and SBTE. Returns "verified",
    "corrupted", or "unchecked" for firmware whose SBTE carries no check.
    Same rule as firmware/camera_stream/telemetry_check.h: CRC-32 over each
    line's bytes without terminators, plus the line count.
    """
    import json
    import zlib
    try:
        end = json.loads(end_line.split(" ", 1)[1])
        expected_lines, expected_crc = int(end["lines"]), int(end["crc32"], 16)
    except (IndexError, KeyError, ValueError, TypeError):
        return "unchecked"
    crc = 0
    for line in lines:
        crc = zlib.crc32(line.rstrip("\r\n").encode("utf-8"), crc)
    return "verified" if crc == expected_crc and len(lines) == expected_lines else "corrupted"


def frame_packet(sequence, payload, version=1):
    """Build a packet, for tests and for anything that needs to fake a link."""
    return MAGIC + struct.pack("<BII", version, sequence, len(payload)) + payload
