#!/usr/bin/env python3
"""Compare the camera stream over USB and over Wi-Fi, with the same settings.

    python3 benchmark_transport.py --tcp stanbot.local --usb /dev/cu.usbmodem31201
    python3 benchmark_transport.py --usb /dev/cu.usbmodem31201          # USB only

With both given, video runs over TCP and the USB link is used only for the
firmware's own Wi-Fi status (SBWF) and timing stats (SBST), which it prints
to USB whatever the video transport. Without --tcp, video runs over USB.

Close Stanbot first: it holds the serial port and would send its own commands.

Per configuration it reports frames per second, throughput, frames the
firmware sent that never arrived (sequence gaps), inter-arrival jitter, and
command latency: how long a V request takes to be answered while frames are
flowing, which is what head following will feel.

From the mini, agent shells cannot reach LAN hosts (macOS Local Network
privacy); run this through `ssh malpern@openclaw.local` instead.
"""
import argparse
import json
import os
import select
import socket
import statistics
import termios
import time

from sbstream import Demuxer

CONFIGS = [
    ("qvga_q90_200ms", ["M,320", "J,90", "R,200"]),
    ("qvga_q90_100ms", ["M,320", "J,90", "R,100"]),
    ("vga_q90_100ms", ["M,640", "J,90", "R,100"]),
    ("raw_qvga_100ms", ["M,raw320", "R,100"]),
]


class Serial:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        self.old = termios.tcgetattr(self.fd)
        raw = termios.tcgetattr(self.fd)
        raw[0] = raw[1] = raw[3] = 0
        raw[2] |= termios.CLOCAL | termios.CREAD
        termios.tcsetattr(self.fd, termios.TCSANOW, raw)

    def send(self, text):
        os.write(self.fd, text.encode())

    def read(self):
        try:
            return os.read(self.fd, 65536)
        except (BlockingIOError, OSError):
            return b""

    def close(self):
        termios.tcsetattr(self.fd, termios.TCSANOW, self.old)
        os.close(self.fd)


class Tcp:
    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock.setblocking(False)
        self.fd = self.sock.fileno()

    def send(self, text):
        self.sock.sendall(text.encode())

    def read(self):
        try:
            data = self.sock.recv(262144)
        except BlockingIOError:
            return b""
        if not data:
            raise RuntimeError("robot closed the TCP connection")
        return data

    def close(self):
        self.sock.close()


def pump(links, duration, on_event):
    """Read every link until duration elapses, feeding each its own demuxer."""
    end = time.monotonic() + duration
    while True:
        left = end - time.monotonic()
        if left <= 0:
            return
        ready, _, _ = select.select([l.fd for l, _ in links], [], [], min(0.05, left))
        for link, demux in links:
            if link.fd in ready:
                data = link.read()
                if data:
                    now = time.monotonic()
                    for kind, value in demux.feed(data):
                        on_event(link, kind, value, now)


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(p / 100 * (len(ordered) - 1))))]


def run_config(name, commands, video, status, seconds):
    links = [(video, Demuxer())] + ([(status, Demuxer())] if status else [])
    frames, texts = [], []
    pending_v, latencies = None, []

    def on_event(link, kind, value, now):
        nonlocal pending_v
        if kind == "frame":
            if link is video:
                sequence, payload = value
                frames.append((now, sequence, len(payload)))
        else:
            line = value if isinstance(value, str) else value.decode("utf-8", "replace")
            texts.append(line)
            if link is video and line.startswith("SBVR") and pending_v is not None:
                latencies.append((now - pending_v) * 1000)
                pending_v = None

    video.send("X\n")
    pump(links, 0.6, lambda *a: None)
    for command in commands:
        video.send(command + "\n")
    if status:
        status.send("Z\n")
    video.send("S\n")
    pump(links, 2.0, lambda *a: None)       # let the rate settle; discard
    frames.clear(); texts.clear()

    start = time.monotonic()
    next_v = start + 1.0
    while time.monotonic() - start < seconds:
        if pending_v is None and time.monotonic() >= next_v:
            pending_v = time.monotonic()
            video.send("V\n")
            next_v = pending_v + 2.0
        pump(links, 0.1, on_event)
    elapsed = time.monotonic() - start
    if status:
        status.send("P\n")
        pump(links, 1.0, on_event)
    video.send("X\n")
    pump(links, 0.8, lambda *a: None)

    gaps = sum(max(0, b[1] - a[1] - 1) for a, b in zip(frames, frames[1:]))
    intervals = [(b[0] - a[0]) * 1000 for a, b in zip(frames, frames[1:])]
    stats = next((json.loads(t[5:]) for t in reversed(texts) if t.startswith("SBST")), None)
    result = {
        "config": name,
        "seconds": round(elapsed, 1),
        "frames": len(frames),
        "fps": round(len(frames) / elapsed, 2),
        "kbytes_per_s": round(sum(f[2] for f in frames) / elapsed / 1024, 1),
        "mean_frame_kb": round(statistics.mean(f[2] for f in frames) / 1024, 1) if frames else None,
        "lost_by_sequence": gaps,
        "interval_ms_p50": round(percentile(intervals, 50), 1) if intervals else None,
        "interval_ms_p95": round(percentile(intervals, 95), 1) if intervals else None,
        "interval_ms_max": round(max(intervals), 1) if intervals else None,
        "interval_ms_stdev": round(statistics.pstdev(intervals), 1) if len(intervals) > 1 else None,
        "command_ms_p50": round(percentile(latencies, 50), 1) if latencies else None,
        "command_ms_max": round(max(latencies), 1) if latencies else None,
        "commands_answered": len(latencies),
        "demux_dropped_bytes": links[0][1].dropped,
    }
    if stats and stats.get("sent"):
        result["firmware_sent"] = stats["sent"]
        result["firmware_send_failures"] = stats["failures"]
        result["firmware_encode_ms_mean"] = round(stats["encode_us"] / max(1, stats["captures"]) / 1000, 1)
        result["firmware_enqueue_ms_mean"] = round(stats["enqueue_us"] / stats["sent"] / 1000, 1)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tcp", help="robot host for Wi-Fi video, e.g. stanbot.local")
    parser.add_argument("--port", type=int, default=3333)
    parser.add_argument("--usb", help="serial device; video over USB unless --tcp is given")
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--only", help="comma-separated config names")
    args = parser.parse_args()
    if not args.tcp and not args.usb:
        parser.error("give --tcp, --usb, or both")

    serial = Serial(args.usb) if args.usb else None
    tcp = Tcp(args.tcp, args.port) if args.tcp else None
    video, status = (tcp, serial) if tcp else (serial, None)
    try:
        if serial and tcp:
            serial.send("W,?\n")
            wifi = []
            pump([(serial, Demuxer())], 1.5,
                 lambda l, k, v, n: wifi.append(v) if k == "text" and str(v).startswith("SBWF") else None)
            if wifi:
                info = json.loads(wifi[-1][5:])
                print(json.dumps({"wifi": {k: info.get(k) for k in ("ssid", "ip", "rssi", "client")}}))
        wanted = set(args.only.split(",")) if args.only else None
        for name, commands in CONFIGS:
            if wanted and name not in wanted:
                continue
            print(json.dumps({"transport": "wifi" if tcp else "usb",
                              **run_config(name, commands, video, status, args.seconds)}), flush=True)
        video.send("M,320\nJ,90\nR,200\n")   # leave the documented defaults
    finally:
        if tcp:
            tcp.close()
        if serial:
            serial.close()


if __name__ == "__main__":
    main()
