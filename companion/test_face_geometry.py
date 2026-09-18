#!/usr/bin/env python3
"""The robot's half of the face contract, and whether the committed copy is current.

`companion/face-geometry.json` is what the robot says its face IS for a set of
named states -- where each thing sits, how big, and what kind -- with nothing
about how it is painted. The Mac's own test reads the same file and checks that
its face agrees (FaceGeometryTests.swift).

Generated and committed rather than produced at build time, so neither
toolchain grows a code-generation step and a design change shows up as a
readable diff in review. This checks the committed copy is not stale:

    python3 companion/test_face_geometry.py            # verify
    python3 companion/test_face_geometry.py --write    # regenerate after a change
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CONTRACT = os.path.join(HERE, "face-geometry.json")


def generate():
    """Ask the firmware's own geometry() what the face is, for every state."""
    with tempfile.TemporaryDirectory() as tmp:
        binary = os.path.join(tmp, "render_face")
        build = subprocess.run(
            ["c++", "-std=c++17", "-include", "initializer_list", "-I", os.path.join(HERE, "stubs"),
             os.path.join(HERE, "render_face.cpp"), "-o", binary],
            capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stderr, file=sys.stderr)
            raise SystemExit("render_face.cpp does not build")
        done = subprocess.run([binary, "--geometry"], capture_output=True, text=True)
        if done.returncode != 0:
            print(done.stderr, file=sys.stderr)
            raise SystemExit("--geometry failed")
        return done.stdout


def sanity(contract):
    """The contract has to describe a face that fits on the screen and reads as
    one. These are the mistakes that actually happened, not hypothetical ones."""
    screen = contract["screen"]
    assert (screen["width"], screen["height"]) == (320, 240), screen
    assert contract["eyeLeftX"] < contract["eyeRightX"], "the eyes are the wrong way round"
    for name, state in contract["states"].items():
        assert state["eyeKind"] in ("open", "closed", "crossed"), (name, state["eyeKind"])
        assert state["eyeWidth"] > 0 and state["eyeHeight"] > 0, name
        assert 0 <= state["shut"] <= 100, (name, state["shut"])
        # An eye must not run off the side. Half the width either side of each
        # eye's centre has to stay on the panel.
        half = state["eyeWidth"] / 2
        assert contract["eyeLeftX"] - half >= 0, "%s: the left eye runs off the edge" % name
        assert contract["eyeRightX"] + half <= screen["width"], "%s: the right eye runs off" % name
        # The frown lives at the bottom and must keep clear of it.
        #
        # Only the TOP of the ring is drawn, so the ink sits ABOVE frownY: the
        # arc sweeps 190..350 degrees, which puts its lowest point about four
        # pixels above the centre and its highest at frownY - radius - stroke.
        # (Measured: centre 210 draws ink from 180 to 206.) Requiring room
        # BELOW frownY, as this check first did, fails a perfectly good face.
        if state["frownVisible"]:
            ink_bottom = state["frownY"] - 4
            ink_top = state["frownY"] - state["frownRadius"] - 5
            assert ink_top > 0, "%s: the frown runs off the top" % name
            # 25 px of air. At frownY=232 the ink reached 228 of 240 -- twelve
            # pixels -- and the face read as sliding off the screen.
            assert screen["height"] - ink_bottom >= 25, \
                "%s: the frown crowds the bottom of the screen (ink ends at %d of %d)" % (
                    name, ink_bottom, screen["height"])
        # Shut eyes have no pupil to aim, and crossed eyes are not "asleep".
        if state["shut"] == 100:
            assert state["eyeKind"] == "closed", "%s: fully shut but drawn as %s" % (name, state["eyeKind"])
        if state["eyeKind"] == "crossed":
            assert state["frownVisible"], "%s: crossed eyes without the frown is half a trouble face" % name

    # The states that carry the design decisions, named so a change to any of
    # them is deliberate rather than incidental.
    states = contract["states"]
    assert states["closed"]["eyeKind"] == "closed"
    assert states["trouble"]["eyeKind"] == "crossed"
    assert states["trouble_closed"]["eyeKind"] == "closed", \
        "being in trouble must not stop Stanbot closing its eyes"
    assert states["trouble_closed"]["frownVisible"], \
        "asleep and faulted should still show the frown: it is still in trouble"
    assert states["speaking"]["mouthVisible"], "the speaking state should have a mouth"
    assert not states["normal"]["mouthVisible"], "a resting face draws no mouth"


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    fresh = generate()

    if "--write" in argv:
        with open(CONTRACT, "w") as f:
            f.write(fresh)
        print("wrote %s" % CONTRACT)
        sanity(json.loads(fresh))
        return 0

    if not os.path.exists(CONTRACT):
        print("missing %s -- run with --write" % CONTRACT, file=sys.stderr)
        return 1
    with open(CONTRACT) as f:
        committed = f.read()
    if json.loads(committed) != json.loads(fresh):
        print("companion/face-geometry.json is STALE: the robot's face has changed.\n"
              "Regenerate it with `python3 companion/test_face_geometry.py --write`,\n"
              "and read the diff -- it is the design change you just made.", file=sys.stderr)
        return 1
    sanity(json.loads(committed))
    print("companion/test_face_geometry.py: the contract is current and sane")
    return 0


if __name__ == "__main__":
    sys.exit(main())
