# USB camera performance — 2026-09-14

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
