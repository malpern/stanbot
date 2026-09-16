# USB camera performance

## The companion was losing two thirds of the stream — 2026-09-15

Raising encoder quality to 90 made the app stop recognising faces. The cause was
not detection and not the robot: it was the Mac reading the serial port on a
50 ms timer.

The robot writes each JPEG as one burst. A 21.7 KB frame at quality 90 lands in
about 24 ms, entirely between two polls, and the terminal input buffer is smaller
than that, so the kernel discards the tail before anyone reads it. The decoder
resyncs and the whole frame is lost. Same robot, same app, only quality changed:

| Quality | Frame size | Frames the app received |
| --- | --- | --- |
| 35 | 6.8 KB | 2.64 per second |
| 90 | 21.7 KB | 0.93 per second |

The robot was sending 3.5 fps throughout. Nothing robot-side showed this, because
the benchmark and capture tools drain the port continuously with large reads.

Evidence that detection was never at fault: 40 consecutive captured frames were
run through the app's exact Vision request and all 40 found the face, confidence
0.76 to 0.84, every box inside the frame and past every validity filter. Those
same boxes replayed through the real selection code reached "Face selected" in
0.6 s. Instrumenting the running app showed the true failure: hits reached 1, a
0.95 s gap tripped the loss window, reset, repeat, indefinitely.

Two independent defects, both fixed:

- **Transport.** The app now reads from a dispatch source that drains the port as
  bytes arrive, so frame size no longer matters. `SerialReader` owns the
  descriptor and closes it on cancel. Disconnect is now noticed by the reader
  rather than inside the UI timer, so it is reported on a later main-queue hop.
- **Selection tolerance.** Loss was expressed in fixed seconds (0.45 and 0.9)
  while acquisition needs three consecutive hits. That silently required about
  3.3 fps: below it, lock-on was impossible rather than slow, and it failed
  looking exactly like a detection problem. Tolerance now scales with the
  measured frame interval, is patient until an interval has actually been
  measured, and survives a reset since it describes the transport, not the face.
  A frame that simply misses the face no longer discards progress; only genuine
  ambiguity, several faces overlapping the selection, still does.

Verified on the robot: the app locks on within about a second and holds.


## Pixel clock re-tested: 7.8 fps is available, but it tears — 2026-09-16

The 2026-09-14 tearing fix (GC0308 page 0 register 0x28, divider bits 6:4 set
to 2) was made while the Mac's reader was still dropping two thirds of the
stream, so it was re-tested with today's pipeline. `D,<n>` now changes the
divider at runtime and `Y,<page>,<reg>[,<value>]` reads or writes any sensor
register, both USB only; `companion/pclk_sweep.py` runs the comparison.

**Sensor rate, stream off** (the camera task only dequeues):

| Divider | Camera fps |
| --- | --- |
| 2 (default) | 5.21 |
| 1 | 7.82 |
| 0 | 7.76 |

The driver's only compiled format is `640x480_yuv422_yuyv_16fps`, and divider
0 should reach it. It does not, and **exposure is not why**: auto exposure was
using 250 rows, and with AEC off (register 0xd2 bit 7) at 400, 200 and 100 rows
the rate stayed at 7.7-7.8. At divider 0 the capture path keeps only every
other frame.

**Both faster settings tear.** Divider 0 produced frames rolled and sliced
vertically, the picture wrapping inside the frame, in every frame checked.
Divider 1 is subtler: a band partway down slips or repeats rows (the sofa
appears doubled), counted in 38 of 70 raw frames across two alternating runs
against 2 of 65 at divider 2, and those 2 were an arm moving through the
region the check watches, not tears. Saved JPEGs at divider 1 showed the same
seams. So the 2026-09-14 tearing was real, not a transport artifact.

**Even untorn, the extra frames would not arrive.** With the stream on at
divider 1 the robot delivered 5.2 fps: each frame costs about 48 ms to shrink,
48 ms to encode and 40 ms to write, about 136 ms, on the core that also
services the capture driver.

What would be needed to go faster, none of it done:

- **Find why capture corrupts at a faster pixel bus.** Signal integrity on the
  camera flex, PCLK sampling edge, or the LCD_CAM/DMA path overrunning are all
  plausible; none was tested.
- **Have the sensor send 320x240.** It would remove the 48 ms shrink and
  quarter the bus data, but the prebuilt driver has only the 640x480 format.
- **Cut per-frame work**, for example a larger USB transmit buffer so writes
  do not block, or esp_new_jpeg's dual-task mode.

The default stays at divider 2.

## Faster encoder and frame pacing — 2026-09-16

**Espressif's `esp_new_jpeg` replaced the esp32-camera jpge encoder.** Both stay
in the build; `K,0` and `K,1` switch between them over USB, so the comparison
ran on one image, one camera and one scene. `companion/benchmark_transport.py`,
20 s per row, over USB, quality 90:

| Setting | Encoder | fps | Interval p95 / max ms | Interval spread ms | Encode ms/frame |
| --- | --- | --- | --- | --- | --- |
| QVGA, 100 ms | jpge | 3.49 | 394 / 400 | 94.6 | ~190 (46 shrink) |
| QVGA, 100 ms | esp_new_jpeg | **5.23** | **203 / 215** | **7.5** | ~95 (48 shrink) |
| QVGA, 200 ms | jpge | 3.48 | 395 / 399 | 92.3 | ~193 |
| QVGA, 200 ms | esp_new_jpeg | 4.93 | 217 / 391 | 43.3 | ~91 |
| VGA, 100 ms | jpge | 1.55 | 650 / 748 | 23.9 | ~484 |
| VGA, 100 ms | esp_new_jpeg | **3.49** | 386 / 388 | 87.3 | ~158 |

The encode column is per captured frame and includes the 2x2 shrink, so JPEG
itself fell from roughly 145 ms to roughly 48 ms at QVGA, and from 484 to 158 at
VGA. Frame sizes are within about 10% at the same quality number. The eyes'
worst stall was unchanged (67 ms against 69), and saved frames from both encoders
were checked by eye: no artifacts, same colour. Espressif's README claims about
22 ms for QVGA; the difference is unexplained, possibly because frames live in
PSRAM.

**At QVGA the stream now runs at the sensor's own rate,** about 5.2 fps with the
pixel clock slowed for the tearing fix. The next ceiling is that clock, not
compression.

**The faster encoder exposed a scheduling bug that halved the rate.** The loop
dequeues every sensor frame (about every 192 ms) and used to send one only if
it arrived at least `interval` after the last send. At 200 ms each frame came
about 8 ms early, so every other one was dropped: 2.59 fps, worse than the old
encoder. The old encoder hid this, because after ~190 ms of encoding the
deadline had always passed. `frame_pacer.h` now keeps a cadence and accepts a
frame up to half an interval (at most 100 ms) early; `companion/test_frame_pacer.cpp`
simulates the sensor and fails against the old rule. Even so, 200 ms averages
5.0 fps by skipping about one frame in 26, and each skip is a 390 ms hitch, so
the default interval is now 100 ms, which sends every frame.

**Over Wi-Fi the gain is smaller, because the radio link became the limit.**
With the robot at -70 dBm (it had been -39 earlier that day), alternating runs
gave jpge 3.15 and 2.94 fps against esp_new_jpeg 3.74 and 3.73, with sending
taking about 100-118 ms per frame in both. Stronger signal should move Wi-Fi
closer to the USB figures; not yet measured.

## Bitrate and downsampling — 2026-09-15

Two changes, both aimed at image quality rather than frame rate.

**Encoder quality raised from 35 to 90.** Swept on the connected robot with the
new `J,<10..95>` diagnostic command, QVGA, 200 ms interval, eight-second samples:

| Quality | Rate | Mean payload | Bits/pixel | Link use |
| --- | --- | --- | --- | --- |
| 35 (previous) | 3.38 fps | 6.8 KB | 0.72 | 23 KB/s |
| 50 | 3.50 fps | 10.9 KB | 1.16 | 38 KB/s |
| 65 | 3.50 fps | 11.8 KB | 1.26 | 41 KB/s |
| 80 | 3.50 fps | 13.6 KB | 1.45 | 48 KB/s |
| **90 (selected)** | **3.50 fps** | **21.7 KB** | **2.32** | **76 KB/s** |
| 95 | 3.38 fps | 32.9 KB | 3.51 | 111 KB/s |

Frame rate is flat from 50 to 90: at QVGA the rate is capped by sensor capture,
not by encoding or the link, which even at 90 carries about 76 KB/s against the
730–900 KB/s this full-speed USB connection was measured to sustain. So roughly
three times the bitrate cost nothing. 95 was rejected: half again the bytes, a
measurable rate drop, and little to see for it.

**VGA is different — there the quality number does cost frame rate**, because
encode time grows with it and already dominates that mode:

| Quality | Rate | Mean payload | Bits/pixel |
| --- | --- | --- | --- |
| 35 | 1.90 fps | 21.9 KB | 0.58 |
| 80 | 1.70 fps | 49.4 KB | 1.32 |
| 90 | 1.60 fps | 74.6 KB | 1.99 |

One constant serves both modes. QVGA is the default and the live path, so it
wins; VGA remains a diagnostic mode and gives up about 16% of its rate.

**The QVGA downsample now box-averages instead of point-sampling.** The previous
code kept one source pixel in four and took both chroma samples from the first
pair, discarding the rest of every 2x2 block. That aliased edges and passed
sensor noise straight into the encoder, which then spent bits on it. Every one
of the eight source pixels behind a pair of output pixels now contributes.
`firmware/camera_stream/downsample.h` is header-only so it can be checked on the
host: `companion/test_downsample.cpp` compares it against an independently
written reference, checks that a flat frame survives exactly, checks that a
one-pixel checkerboard (pure aliasing energy) resolves to its true local mean,
and is run under AddressSanitizer and UBSan for bounds.

```sh
c++ -std=c++17 -O1 -fsanitize=address,undefined -Wall -Wextra \
    companion/test_downsample.cpp -o /tmp/td && /tmp/td
```

Not established by any of this: absolute image quality, low-light behaviour,
whether face detection improves with the extra bitrate, or anything about VGA
image quality beyond the rates above. Visual confirmation so far is one live
look at the companion app after the change.

# Earlier measurements — 2026-09-14

Measured on the connected StackChan and Mini, with animated eyes enabled,
the slower GC0308 pixel clock retained, and no motor initialization or commands.
Camera images stayed local and were not saved by the benchmark.

| Output | Requested interval | Received rate | Mean payload | Preparation/frame | USB write/frame |
| --- | --- | --- | --- | --- | --- |
| VGA JPEG, previous pacing | 750 ms | 1.34 fps | 19.6 KB | 498 ms | 22 ms |
| VGA JPEG | 200 ms | 1.92 fps | 19.9 KB | 498 ms | 22 ms |
| QVGA JPEG | 200 ms | 3.54 fps | 7.9 KB | 170 ms | 9 ms |
| QVGA raw YUYV + CRC32 | 100 ms | 3.50 fps | 153.6 KB | 41 ms | 210 ms |

These are eight-second samples, not guaranteed rates. Requesting 100 ms instead
of 200 ms did not improve JPEG throughput. Every sample had zero malformed
complete packets; raw packets also passed CRC32 checks. JPEG checks validate
start/end markers, not every pixel or full decoding.

After flashing the selected default, a 30-second run received 105 frames at
3.48 fps with zero malformed packets (mean payload 7462 bytes). Firmware
reported zero send/encode failures and a maximum eye-present gap of 65 ms.
A separate streaming-off sample dequeued 31 sensor frames in 5.944 seconds
(about 5.2 fps), with no JPEG or USB payload work. Thus capture at the current
anti-tearing clock is itself limited; these results do not imply a high-rate
sensor stream is available under this configuration.

The selected default is **320×240 JPEG, quality 35, 200 ms minimum interval**.
The sensor still captures 640×480 YUYV; the robot downsamples before compression.
This is not a sensor-resolution change. Raw transport uses about 19 times as
many bytes without a measured rate advantage. Mini-side raw color conversion
was not benchmarked. Keep JPEG preparation on the robot for now and face
detection on the Mini; no cloud processing is involved.

## Measurement limits

- `capture_wait_us` measures buffer dequeue wait, not sensor exposure time.
- `encode_us` includes downsampling and compression, or downsampling and CRC
  for raw mode. It is not solely encoder execution time.
- `enqueue_us` measures time spent writing to Serial, not full wire latency.
- `jpeg_bytes` is a legacy field name: it counts payload bytes even in raw mode
  (excluding the raw CRC trailer).
- Host and firmware counts can differ by an in-flight frame at sample boundaries.
- Maximum instrumented eye-present gaps were 64–70 ms in the short tests.
  This is not a substitute for physical observation of animation quality.
- Physical unplug/replug and cold-start validation of this configuration remain
  separate checks. Factory restoration has not been physically validated.

## Reproduce

Close Stanbot first so only one process owns the verified serial port:

```sh
python3 companion/benchmark_camera.py /dev/cu.usbmodem31201 --mode 320 --intervals 200 --seconds 30
```

The tool saves no images and restores stopped streaming, QVGA JPEG, and the
200 ms interval on exit. `--idle` measures capture with streaming off.
`--mode raw320` is **benchmark-only**: the Mac app does not decode raw version-2
packets. Do not run the app simultaneously with the benchmark.
