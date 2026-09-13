# stanbot

Local-first custom firmware for an official M5Stack StackChan, with a Mac mini companion.

## Goal

On startup, display a simple animated avatar, detect a person with the camera, smoothly follow them with the head, and show a confidence-qualified attention indication. Face detection must never be presented as confirmed eye contact. Keep basic avatar and following behavior on-device if feasible; use local companion processing when needed.

## Status

The project has a safe animated-eye firmware slice, an explicit factory-recovery workflow, and a local camera transport probe. USB flashing, the base animated display renderer, and local 640×480 camera frame capture have been tested on the attached StackChan. Servo motion remains deliberately disabled pending physical calibration. Image quality, face detection, and head following are not yet hardware-verified.

## Mini companion control app

`companion/StanbotCompanion` is a native macOS SwiftUI app. It is intentionally
local and conservative: it opens the selected USB serial device, shows whether
the control connection is available, sends display-only expression commands,
and can render bounded local camera frames with macOS Vision face rectangles.
The rectangle is labelled `person detected`, never eye contact or identity.
Head movement remains unavailable until calibration is complete.

```sh
cd companion/StanbotCompanion
./build-app.sh
open build/Stanbot.app
```

See [project brief](docs/project-brief.md) and [hardware coverage](docs/hardware-coverage.md).

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
