# Firmware

## Current combined eyes + camera build

`camera_stream/camera_stream.ino` combines the shared `lib/StanbotEyes`
renderer with USB camera streaming. It starts in Normal, blinks about every
19–30 seconds, and accepts newline-terminated `S` (stream on), `X` (stream off),
and `E,<name>` for all eighteen expressions. Input lines are bounded and unknown
commands are ignored. No target or motor commands are accepted.

The main loop exclusively owns the double-buffered eye display and command
reader. A separate core-0 task owns camera initialization, capture, JPEG
compression, and USB output. Neither calls StackChan's servo initialization.
Camera failure leaves the eyes running. M5Unified initializes board power before
handing the internal I2C bus to the video driver; do not call `M5.update()` while
the video driver owns that bus.

```sh
arduino-cli compile \
  --fqbn 'esp32:esp32:m5stack_cores3:PSRAM=enabled,USBMode=hwcdc,CDCOnBoot=cdc' \
  --libraries firmware/lib firmware/camera_stream
```

Use the recovery notes for flashing. A normal physical power cycle may be
needed after upload: watchdog reset has not been reliable on this board.
Horizontal camera tearing remains a separate issue; correct packet framing
does not establish image quality. See the hardware coverage record for tests.

## Historical avatar-only slice

`stanbot/stanbot.ino` is the first, deliberately safe firmware slice. It uses
the official `StackChan-BSP` submodule for display, RGB, battery and servo
interfaces. It has a local avatar and a bounded head-control state machine,
but it ships with motor output disabled (`kMotionArmed = false`) until the
physical calibration procedure is completed.

This is intentional: the board is connected, but its unique safe directions,
home point and range have not yet been measured. A successful compile is not a
hardware validation.

## Build

The mini has Arduino CLI and Espressif's `esp32` core `3.3.11`, matching the
official BSP's CI. Libraries must be installed once with:

```sh
arduino-cli lib install M5Unified@0.2.21 IRremoteESP8266@2.8.6 M5Unit-NFC@0.1.0
```

From the repository root:

```sh
git submodule update --init --recursive
arduino-cli compile \
  --fqbn esp32:esp32:esp32s3:FlashMode=qio,FlashSize=16M,PSRAM=opi,USBMode=hwcdc,CDCOnBoot=cdc \
  --libraries firmware/lib \
  firmware/stanbot
```

Do not upload this sketch until the factory-recovery procedure and physical
calibration checklist are complete. The expected device port is currently
`/dev/cu.usbmodem31201`; confirm it by disconnect/reconnect before any upload.

The current build on the mini completed successfully: 588,499 bytes of flash
(44% of the selected 16 MB layout) and 28,852 bytes of RAM (8%). It was not
uploaded.

See [face-detection.md](../docs/face-detection.md) and
[recovery.md](../docs/recovery.md).
