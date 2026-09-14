#!/usr/bin/env python3
"""Local USB camera benchmark. Close Stanbot first; saves no camera images.

Reports host-observed JPEG arrivals and firmware timings. enqueue_us measures
time in Serial.write, not USB wire completion; capture_wait_us is dequeue wait,
not exposure time. Run only against the verified StackChan serial port.
"""
import argparse
import json
import os
import select
import struct
import termios
import time
import zlib


class Reader:
    def __init__(self, fd):
        self.fd = fd
        self.buffer = bytearray()
        self.frames = []
        self.invalid = 0
        self.stats = None

    def pump(self, duration):
        end = time.monotonic() + duration
        while time.monotonic() < end:
            if not select.select([self.fd], [], [], min(.05, max(0, end - time.monotonic())))[0]:
                continue
            try:
                data = os.read(self.fd, 65536)
            except BlockingIOError:
                continue
            if not data:
                raise RuntimeError("USB disconnected")
            self.buffer.extend(data)
            while len(self.buffer) >= 5:
                b = self.buffer
                if b.startswith(b"SBFR"):
                    if len(b) < 13:
                        break
                    length = struct.unpack_from("<I", b, 9)[0]
                    if b[4] not in (1, 2) or not 1 <= length <= 300000:
                        del b[0]
                        self.invalid += 1
                        continue
                    if len(b) < 13 + length:
                        break
                    valid = (b[13:15] == b"\xff\xd8" and b[11+length:13+length] == b"\xff\xd9") if b[4] == 1 else (
                        length == 153604 and zlib.crc32(b[13:13+length-4]) == struct.unpack_from("<I", b, 13+length-4)[0])
                    if not valid:
                        self.invalid += 1
                        del b[0]
                        continue
                    self.frames.append((time.monotonic(), length))
                    del b[:13+length]
                elif b.startswith(b"SBST "):
                    newline = b.find(b"\n")
                    if newline < 0:
                        if len(b) > 2048:
                            raise RuntimeError("Oversized stats message")
                        break
                    self.stats = json.loads(b[5:newline])
                    del b[:newline+1]
                else:
                    del b[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--mode", choices=["640", "320", "raw320"], default="640")
    parser.add_argument("--idle", action="store_true", help="Measure capture/dequeue only, with USB video disabled")
    parser.add_argument("--intervals", type=int, nargs="+", default=[750, 333, 200, 100], choices=[750, 333, 200, 100])
    args = parser.parse_args()
    if not 3 <= args.seconds <= 60:
        parser.error("seconds must be between 3 and 60")
    fd = os.open(args.port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    old = termios.tcgetattr(fd)
    settings = termios.tcgetattr(fd)
    settings[0] = settings[1] = settings[3] = 0
    settings[2] |= termios.CLOCAL | termios.CREAD
    settings[6][termios.VMIN] = 1
    settings[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, settings)
    try:
        for interval in args.intervals:
            os.write(fd, b"X\n")
            Reader(fd).pump(2)
            reader = Reader(fd)
            stream_command = "X" if args.idle else "S"
            os.write(fd, f"M,{args.mode}\nR,{interval}\nZ\n{stream_command}\n".encode())
            reader.pump(args.seconds)
            os.write(fd, b"X\nP\n")
            reader.pump(2)
            frames = reader.frames
            fps = ((len(frames)-1)/(frames[-1][0]-frames[0][0])) if len(frames) > 1 else 0
            print(json.dumps({"mode": "capture-only" if args.idle else args.mode, "requested_interval_ms": interval, "observed_fps": round(fps, 2),
                "received_frames": len(frames), "invalid_packets": reader.invalid,
                "mean_payload_bytes": round(sum(n for _, n in frames)/len(frames)) if frames else 0,
                "firmware": reader.stats}), flush=True)
            if (not frames and not args.idle) or reader.stats is None:
                raise RuntimeError("No frames or firmware timings; benchmark incomplete")
    finally:
        try:
            os.write(fd, b"X\nR,200\nM,320\n")
            termios.tcsetattr(fd, termios.TCSANOW, old)
        finally:
            os.close(fd)


if __name__ == "__main__":
    main()
