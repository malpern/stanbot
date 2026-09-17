# stanbot

Local-first custom firmware for an official M5Stack StackChan, with a Mac mini companion.

## Goal

On startup, display a simple animated avatar, detect a person with the camera, smoothly follow them with the head, and show a confidence-qualified attention indication. Face detection must never be presented as confirmed eye contact. Keep basic avatar and following behavior on-device if feasible; use local companion processing when needed.

## Status

Working on the attached robot, as of 2026-09-17:

- **Head following.** The Mac app finds faces in the robot's camera picture and
  the head follows the selected one, left-right and up-down, continuously:
  sessions repeat on their own, each on a renewable motor-power lease with a
  3-minute maximum. It searches when it loses you and returns to rest. Yaw is
  limited to +-96 raw (about 30 degrees) and pitch to 594..870 (rest to just
  short of vertical) while calibration is widened one supervised step at a time.
- **A calm face.** Two grey eyes with 19 expressions, a body light bar that is
  blue with a face and breathes orange without one, a mouth that moves while
  the Mac plays speech, and a "trouble" face after the Sad Mac when something
  is wrong.
- **Sleep and wake.** The robot closes its eyes, darkens its screen and light
  bar and stays on Wi-Fi; the app shows waking as a shot from behind its eyes.
  On waking it looks around the room for someone (built; first run pending).
- **Wi-Fi first.** Camera, control and firmware updates all go over Wi-Fi, with
  USB as the fallback and the recovery path. Starting motion, rebooting and
  powering off over Wi-Fi need a passphrase challenge.
- **It says when it is broken.** The robot reports the health of its link to
  its base, the app shows faults plainly, and nothing retries into silence.

Not done: widening yaw beyond +-96, the wake scan's first supervised run, the
spoken conversation (planned in [voice](docs/voice.md): the mouth is built, the
conversation is not), and everything in [hardware coverage](docs/hardware-coverage.md)
still marked unverified.

Start with [next session](docs/next-session.md): what is on the robot, what has
not been seen by eye, what comes next, and how to build, flash and test. Then
[head following](docs/head-following.md), [app design](docs/app-design.md) and
[transport](docs/transport.md). Face detection is never presented as eye
contact or identity.

Every servo position settles 2-6 raw steps short of its goal, which is the
factory configuration rather than a fault; see
[servo startup review](docs/servo-startup-review.md).

## The Mac app

`companion/StanbotCompanion` is a native macOS SwiftUI app, Stanbot.

- **The window is the robot's view:** the camera picture at the top, mirrored
  like a selfie camera, with the selected face outlined. Nothing floats over it.
- **Title bar:** Stanbot's name, and a red dot only when something is wrong.
- **Toolbar:** Sleep/Wake and the controls panel toggle.
- **Controls panel** (right, hideable): Stanbot's face, large. Click it to
  sleep or wake the robot. A gear opens Head (Follow/Stop, follow automatically,
  a direction pad for pointing the head by hand), Camera, Expression and
  Connection.
- **Diagnostics** (Window menu): live status, recent follow sessions with their
  results, and the activity log.
- **Settings** (Stanbot menu): general, connection and video preferences.

**Transport** (in the gear): Wi-Fi falling back to USB (the default), Wi-Fi only
(never opens the serial port, leaving it free for scripts), or USB only (never
touches the network). Stored under `StanbotTransport`, so
`open Stanbot.app --args -StanbotTransport usb` overrides it for one launch.

**Video** settings improve what is displayed, never what face detection sees:
color, temporal noise reduction, smooth motion and 2x upscaling, the last three
through the macOS 26 VideoToolbox frame processors. See
[camera performance](docs/camera-performance.md#mac-side-enhancement--2026-09-16).

```sh
cd companion/StanbotCompanion
swift test && ./build-app.sh
open build/Stanbot.app
```

Close the app before running the USB bench tools (`companion/probe_servos.py`,
`companion/find_pitch_level.py`, `tools/check_sleep_wake.py`).

See [project brief](docs/project-brief.md), [hardware coverage](docs/hardware-coverage.md),
and [transport](docs/transport.md) for what the link can and cannot do.

## Development sequence

1. Verify official source, board support, and factory recovery instructions.
2. Inspect companion build tools and USB devices; prepare a buildable project.
3. Implement boot → avatar → local USB camera handoff → safe head following → attention indication → lost-target behavior.
4. Prepare and verify the USB flash and factory recovery workflow before requesting a physical connection.
5. Validate hardware, then add OTA with USB recovery retained.

## References to evaluate

- [M5Stack StackChan guide](https://docs.m5stack.com/en/StackChan)
- [Official StackChan source](https://github.com/m5stack/StackChan)
- [StackChan BSP](https://github.com/m5stack/StackChan-BSP)
- [Espressif ESP-WHO](https://github.com/espressif/esp-who)
- [Community stackchan-mcp](https://github.com/kisaragi-mochi/stackchan-mcp)

The official resources have now been evaluated. The StackChan uses a CoreS3
(ESP32-S3, 16 MB flash, 8 MB PSRAM) and its official BSP is pinned as a
submodule. See [local companion architecture](docs/companion-architecture.md),
[recovery](docs/recovery.md), and [hardware coverage](docs/hardware-coverage.md).
