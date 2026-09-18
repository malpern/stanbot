#!/usr/bin/env python3
"""Checks for companion/render_face.cpp: it builds, and it draws real faces.

The renderer exists so a face can be looked at without a robot. That is only
worth anything if it keeps working, and "it produced a file" is not the same as
"it drew a face" -- an all-black 320x240 PNG would pass that and tell nobody
anything. So these check the ink: that there is some, that it is inside the
panel, and that the expressions are actually different from one another.

Stdlib only; the PNG is written with stored deflate blocks, so zlib reads it.
"""
import os
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WIDTH, HEIGHT = 320, 240


def build(into):
    binary = os.path.join(into, "render_face")
    done = subprocess.run(
        ["c++", "-std=c++17", "-include", "initializer_list", "-I", os.path.join(HERE, "stubs"),
         os.path.join(HERE, "render_face.cpp"), "-o", binary],
        capture_output=True, text=True)
    if done.returncode != 0:
        print(done.stderr, file=sys.stderr)
        raise SystemExit("render_face.cpp does not build")
    return binary


def read_png(path):
    """(width, height, rows of (r,g,b)) from our own writer's output."""
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    offset, width, height, idat = 8, 0, 0, b""
    while offset < len(data):
        length = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        body = data[offset + 8:offset + 8 + length]
        if kind == b"IHDR":
            width, height = struct.unpack_from(">II", body, 0)
        elif kind == b"IDAT":
            idat += body
        offset += 12 + length
    raw = zlib.decompress(idat)
    stride = width * 3
    rows = []
    for y in range(height):
        start = y * (stride + 1)
        assert raw[start] == 0, "unexpected PNG filter"
        line = raw[start + 1:start + 1 + stride]
        rows.append([tuple(line[x * 3:x * 3 + 3]) for x in range(width)])
    return width, height, rows


def lit(rows):
    """Coordinates of every pixel that is not background black."""
    return [(x, y) for y, row in enumerate(rows)
            for x, pixel in enumerate(row) if sum(pixel) > 30]


def render(binary, out, *args):
    done = subprocess.run([binary, "--out", out, *args], capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    return read_png(out)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        binary = build(tmp)
        out = os.path.join(tmp, "face.png")

        # Every expression the firmware knows must render something.
        expressions = ["normal", "angry", "glee", "happy", "sad", "worried", "focused",
                       "annoyed", "surprised", "skeptic", "frustrated", "unimpressed",
                       "sleepy", "suspicious", "squint", "furious", "scared", "awe", "trouble"]
        inked = {}
        for name in expressions:
            width, height, rows = render(binary, out, "--expression", name)
            assert (width, height) == (WIDTH, HEIGHT), (name, width, height)
            pixels = lit(rows)
            assert len(pixels) > 500, "%s drew almost nothing (%d px)" % (name, len(pixels))
            # Nothing may sit outside the panel: the robot's screen clips, so
            # ink beyond it is invisible there and a silent design error.
            for x, y in pixels:
                assert 0 <= x < WIDTH and 0 <= y < HEIGHT, (name, x, y)
            inked[name] = len(pixels)

        # Expressions must actually differ. A renderer that drew the same face
        # for every mood would pass every check above.
        assert len(set(inked.values())) > len(expressions) // 2, \
            "too many expressions render identically: %r" % inked

        # The one we most want to be able to look at without a robot.
        _, _, rows = render(binary, out, "--expression", "trouble")
        assert len(lit(rows)) > 1000, "the trouble face should be substantial"

        # Closed eyes: fewer lit pixels than open ones, and they sit in a band
        # rather than filling the eye.
        _, _, open_rows = render(binary, out, "--expression", "normal")
        _, _, shut_rows = render(binary, out, "--expression", "normal", "--closing", "1.0")
        open_pixels, shut_pixels = lit(open_rows), lit(shut_rows)
        assert len(shut_pixels) < len(open_pixels) / 2, \
            "closed eyes should use far less ink than open ones (%d vs %d)" % (
                len(shut_pixels), len(open_pixels))
        shut_ys = [y for _, y in shut_pixels]
        assert max(shut_ys) - min(shut_ys) < 40, "a closed eye should be a band, not a blob"

    print("companion/test_render_face.py: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
