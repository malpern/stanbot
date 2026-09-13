# Firmware

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
