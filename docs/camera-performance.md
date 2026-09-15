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
