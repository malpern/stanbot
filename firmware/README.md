# Firmware

## Current combined eyes + camera build

`camera_stream/camera_stream.ino` combines the shared `lib/StanbotEyes`
renderer with USB camera streaming. It starts in Normal, blinks about every
19–30 seconds, and accepts newline-terminated `S` (stream on), `X` (stream off),
and `E,<name>` for all eighteen expressions. Input lines are bounded and unknown
commands are ignored. No target or motor commands are accepted.

The default stream is 320×240 JPEG at a 200 ms minimum interval (measured about
3.5 fps). The sensor remains VGA; downsampling occurs before JPEG compression.
See [camera performance](../docs/camera-performance.md) for measurements and limits.
Diagnostic newline commands are `P` (timing stats), `Z` (reset stats),
`R,750|333|200|100` (choose one interval in ms), and `M,640|320|raw320`
(choose one output mode). Raw mode is benchmark-only, not supported by the app.
JPEG uses SBFR version 1; raw uses version 2 with 153600 YUYV bytes followed by a
little-endian CRC32. Stats use a separate `SBST ` JSON line between packets.

`Q` performs a read-only base/servo preflight, returning `SBSC` JSON lines.
It reads the base expander at 0x6f on the existing camera I2C bus, then servo
IDs 1 and 2 over the official UART1 TX6/RX7 mapping. It does not enable motor
power, torque, change EEPROM, or send position goals. With the app closed:
`python3 companion/probe_servos.py /dev/cu.usbmodem31201`.
Missing/invalid feedback exits nonzero and must never be treated as position zero.

Supervised `C,POWERTEST` (host `--power-test`) is a separate, explicitly mutating
preflight: one attempt per boot with streaming stopped. It briefly requests VM
power, broadcasts torque-off, and queries feedback only after torque reads zero.
VM configuration now matches the BSP pull-up/no-pull-down setup and is read
back while low. Output mode, latch and input must all indicate enabled before
the test proceeds to servo queries; a write acknowledgement alone is insufficient.
It never enables torque or sends position/mode/EEPROM commands. A separate task
requests VM off after two seconds or earlier completion; I2C failures can prevent
physical cutoff, so the operator must remain present. The report verifies the
output latch and input signal are low, not a measured motor-rail voltage. No USB
output occurs while the power window is active. This is not motion calibration.

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
The camera now sets and verifies a slower GC0308 pixel-clock divider to avoid
the horizontal tearing observed at the default sensor rate. Correct packet
framing alone does not establish image quality; see hardware coverage for the
limited live visual checks and remaining validation.

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
