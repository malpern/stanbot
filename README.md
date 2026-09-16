# stanbot

Local-first custom firmware for an official M5Stack StackChan, with a Mac mini companion.

## Goal

On startup, display a simple animated avatar, detect a person with the camera, smoothly follow them with the head, and show a confidence-qualified attention indication. Face detection must never be presented as confirmed eye contact. Keep basic avatar and following behavior on-device if feasible; use local companion processing when needed.

## Status

The project has an animated-eye firmware slice, an explicit factory-recovery
workflow, a local camera stream, and supervised bounded head motion. Verified on
the attached robot: USB flashing and factory restore, the animated display, live
640×480 capture streamed as QVGA JPEG, and a full 180° yaw sweep plus a first 5°
pitch move, both observed physically. The companion app locks onto a face and
holds it.

Not yet verified: sustained head following, pitch travel beyond 5°, image quality
under varied lighting, and anything over Wi-Fi. Head following remains off, and
servo travel is bounded by explicit guards rather than by a measured calibration.
Every servo position settles 2–6 raw steps short of its goal, which is the
factory configuration rather than a fault; see
[servo startup review](docs/servo-startup-review.md).

## Mini companion control app

`companion/StanbotCompanion` is a native macOS SwiftUI app. It is intentionally
local and conservative: it opens the selected USB serial device, shows whether
the control connection is available, sends display-only expression commands,
and renders bounded local camera frames with macOS Vision face rectangles.
The rectangle is labelled `person detected`, never eye contact or identity.

The camera feed starts by itself once the USB connection is up, and restarts on
every automatic reconnect: the feed is the point of the app, so it does not wait
for a button. Stop Camera stops it and it stays stopped until asked for again.
Only one process can hold the serial port, so close the app before running
`companion/probe_servos.py`.
Head movement remains unavailable until calibration is complete.

**Transport** is chosen in Stanbot → Settings (⌘,):

- **Wi-Fi, falling back to USB** (default). Uses Wi-Fi when the robot is on the
  network, the side-port USB cable when it is not, and moves back to Wi-Fi when
  the robot reappears, retrying every 30 seconds.
- **Wi-Fi only.** Never opens the serial port, so it stays free for scripts.
- **USB only.** Never contacts the robot over the network.

The choice is stored under `StanbotTransport` (`automatic`, `wifi`, `usb`), so
`open Stanbot.app --args -StanbotTransport usb` overrides it for one launch.

```sh
cd companion/StanbotCompanion
./build-app.sh
open build/Stanbot.app
```

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
