#!/usr/bin/env python3
"""Sweep the GC0308 pixel-clock divider and check each setting for tearing.

    python3 pclk_sweep.py /dev/cu.usbmodem31201 --dividers 2,1,0 --out /tmp/pclk

USB only; close Stanbot first. For each divider (D,<n>, firmware 2026-09-16+):

1. JPEG phase (M,320, R,100): the sensor's capture rate from the firmware's own
   counters, frames delivered per second, interval spread, and failed frames.
   Saves three JPEGs.
2. Raw phase (M,raw320): uncompressed YUYV frames checked for tearing. On this
   unit a torn frame is a horizontal band that slipped or repeated rows, so
   within a static part of the scene (the left `--static-columns`) its row
   brightness departs from the median frame over a run of rows. A frame with a
   run of at least 6 rows more than 12 levels off is counted as torn and saved.
   Movement in that region also counts, so compare against divider 2 in the
   same session, and look at the saved frames before trusting a count.

   An earlier version scored sideways row displacement instead. It reported
   zero at dividers 0 and 1 while the saved frames were visibly torn and, at 0,
   rolled vertically. Do not bring it back.

The robot is left at divider 2, the boot default, whatever happens.
"""
import argparse
import json
import os
import select
import struct
import termios
import time
import zlib

import numpy as np

from sbstream import Demuxer


class Link:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        self.old = termios.tcgetattr(self.fd)
        raw = termios.tcgetattr(self.fd)
        raw[0] = raw[1] = raw[3] = 0
        raw[2] |= termios.CLOCAL | termios.CREAD
        termios.tcsetattr(self.fd, termios.TCSANOW, raw)
        self.demux = Demuxer()

    def send(self, *commands):
        for command in commands:
            os.write(self.fd, (command + "\n").encode())
            time.sleep(0.05)

    def pump(self, seconds):
        frames, texts = [], []
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if select.select([self.fd], [], [], 0.05)[0]:
                try:
                    data = os.read(self.fd, 262144)
                except OSError:
                    continue
                now = time.monotonic()
                for kind, value in self.demux.feed(data):
                    if kind == "frame":
                        frames.append((now, value[0], value[1]))
                    else:
                        texts.append(value)
        return frames, texts

    def close(self):
        termios.tcsetattr(self.fd, termios.TCSANOW, self.old)
        os.close(self.fd)


def png_gray(path, image):
    height, width = image.shape
    raw = b"".join(b"\x00" + image[row].tobytes() for row in range(height))
    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def luma(payload):
    """Raw packets are 153600 YUYV bytes plus a 4-byte CRC32."""
    body = payload[:320 * 240 * 2]
    if len(body) != 320 * 240 * 2 or zlib.crc32(body) & 0xffffffff != struct.unpack("<I", payload[-4:])[0]:
        return None
    return np.frombuffer(body, dtype=np.uint8).reshape(240, 640)[:, 0::2].copy()


def torn_frames(lumas, static_columns, threshold=12, min_run=6):
    """Indices of frames with a band of rows unlike the median frame."""
    if not lumas:
        return []
    profiles = np.array([y[:, :static_columns].mean(axis=1) for y in lumas])
    reference = np.median(profiles, axis=0)
    torn = []
    for index, profile in enumerate(profiles):
        run = best = 0
        for off in np.abs(profile - reference) > threshold:
            run = run + 1 if off else 0
            best = max(best, run)
        if best >= min_run:
            torn.append(index)
    return torn


def firmware_stats(texts):
    stats = [json.loads(t[5:]) for t in texts if t.startswith("SBST")]
    return stats[-1] if stats else None


def run_divider(link, divider, seconds, out, static_columns):
    link.send("X")
    link.pump(0.6)
    link.send(f"D,{divider}")
    _, texts = link.pump(1.5)
    applied = [json.loads(t[5:]) for t in texts if t.startswith("SBCM")]
    result = {"divider": divider, "applied": applied[-1] if applied else None}
    if not applied or not applied[-1]["ok"]:
        return result

    # JPEG phase.
    link.send("K,1", "M,320", "R,100", "Z", "S")
    link.pump(2.0)
    frames, _ = link.pump(seconds)
    link.send("P")
    _, texts = link.pump(1.0)
    link.send("X")
    link.pump(0.6)
    stats = firmware_stats(texts)
    intervals = [(b[0] - a[0]) * 1000 for a, b in zip(frames, frames[1:])]
    gaps = sum(max(0, b[1] - a[1] - 1) for a, b in zip(frames, frames[1:]))
    result["jpeg"] = {
        "delivered_fps": round(len(frames) / seconds, 2),
        "sensor_fps": round(stats["captures"] / (stats["elapsed_ms"] / 1000), 2) if stats else None,
        "interval_ms_p95": round(float(np.percentile(intervals, 95)), 1) if intervals else None,
        "interval_ms_max": round(max(intervals), 1) if intervals else None,
        "interval_ms_sd": round(float(np.std(intervals)), 1) if intervals else None,
        "lost_by_sequence": gaps,
        "firmware_failures": stats["failures"] if stats else None,
        "max_eye_gap_ms": stats["max_eye_gap_ms"] if stats else None,
    }
    for i, index in enumerate(np.linspace(0, len(frames) - 1, 3).astype(int) if frames else []):
        with open(os.path.join(out, f"d{divider}_jpeg{i}.jpg"), "wb") as f:
            f.write(frames[index][2])

    # Raw phase.
    link.send("M,raw320", "R,100", "Z", "S")
    link.pump(2.0)
    frames, _ = link.pump(min(seconds, 12))
    link.send("X", "M,320")
    link.pump(0.6)
    lumas = [l for l in (luma(f[2]) for f in frames) if l is not None]
    torn = torn_frames(lumas, static_columns)
    result["raw"] = {
        "frames": len(frames),
        "crc_ok": len(lumas),
        "torn_frames": len(torn),
        "torn_percent": round(100 * len(torn) / len(lumas)) if lumas else None,
    }
    for i, l in enumerate(lumas[:2]):
        png_gray(os.path.join(out, f"d{divider}_raw{i}.png"), l)
    for i in torn[:3]:
        png_gray(os.path.join(out, f"d{divider}_torn{i}.png"), lumas[i])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("port")
    parser.add_argument("--dividers", default="2,1,0")
    parser.add_argument("--seconds", type=float, default=15)
    parser.add_argument("--out", default="pclk_sweep")
    parser.add_argument("--static-columns", type=int, default=150,
                        help="left columns of the 320-wide frame that hold a still scene")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    link = Link(args.port)
    try:
        for divider in (int(d) for d in args.dividers.split(",")):
            print(json.dumps(run_divider(link, divider, args.seconds, args.out, args.static_columns)), flush=True)
    finally:
        link.send("X", "D,2", "M,320", "R,100", "K,1")
        _, texts = link.pump(1.5)
        restored = [t for t in texts if t.startswith("SBCM")]
        print(json.dumps({"restored": json.loads(restored[-1][5:]) if restored else None}))
        link.close()


if __name__ == "__main__":
    main()
