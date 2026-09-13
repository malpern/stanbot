# stanbot

Local-first custom firmware for an official M5Stack StackChan, with a Mac mini companion.

## Goal

On startup, display a simple animated avatar, detect a person with the camera, smoothly follow them with the head, and show a confidence-qualified attention indication. Face detection must never be presented as confirmed eye contact. Keep basic avatar and following behavior on-device if feasible; use local companion processing when needed.

## Status

Project initialized. No firmware implemented, build verified, or hardware tested yet. The robot is reported to be running factory firmware and has not yet been connected to the companion by USB-C.

See [project brief](docs/project-brief.md) and [hardware coverage](docs/hardware-coverage.md).

## Development sequence

1. Verify official source, board support, and factory recovery instructions.
2. Inspect companion build tools and USB devices; prepare a buildable project.
3. Implement boot → avatar → camera face detection → safe head following → attention indication → lost-target behavior.
4. Prepare and verify the USB flash and factory recovery workflow before requesting a physical connection.
5. Validate hardware, then add OTA with USB recovery retained.

## References to evaluate

- [M5Stack StackChan guide](https://docs.m5stack.com/en/StackChan)
- [Official StackChan source](https://github.com/m5stack/StackChan)
- [StackChan BSP](https://github.com/m5stack/StackChan-BSP)
- [Espressif ESP-WHO](https://github.com/espressif/esp-who)
- [Community stackchan-mcp](https://github.com/kisaragi-mochi/stackchan-mcp)

These references have not yet been evaluated in this repository.
