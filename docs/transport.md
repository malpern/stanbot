# Transport: what the link can and cannot do

Measured facts about getting data between the robot and the Mac, and the
reasoning they settle. Most of this was re-derived more than once during
bring-up; it is written down so it is not re-derived again.

## The two USB-C ports

The official documentation is explicit that **both** ports carry data, and it
recommends the **base** port for programming, so a turning head cannot drag the
cable it is attached to.

**On this particular robot the base port does not enumerate.** Verified in both
plug orientations, with the same cable that works in the head port, on 2026-09-14
and again on 2026-09-15. Power does reach the base: the red LED follows the
cable and rear insertion has lit the screen. So this is a fault in this unit,
not a design limit, and the likely path is the internal seven-wire base-to-head
cable. [Issue 78](https://github.com/m5stack/StackChan/issues/78) reports the
same symptom set on another unit, with charging through the base also failing.

Consequences while it stays broken:

- All USB **data** goes through the head port, including every flash.
- The head port is the recovery path if anything else fails.
- Base-port power is still useful, because it is the stationary connector.

## USB speed is the robot's limit, not the Mac's

The link negotiates to its slowest end, and the ESP32-S3's built-in serial
peripheral is **USB 1.1 full speed, 12 Mbit/s**, with no faster mode. Read off
the live bus on 2026-09-15:

| Device | Negotiated speed |
| --- | --- |
| StackChan | Full speed, 12 Mbit/s |
| The hub it is plugged into | High speed, 480 Mbit/s |
| A USB3 Gen2 hub on the same tree | 10 Gbit/s |

Measured payload throughput is 730–900 KB/s after framing overhead. **A
Thunderbolt port, a different cable, or a different hub cannot change this.**
Check `"Device Speed"` in `ioreg -p IOUSB -l` before blaming anything upstream.

## A polled reader loses data; this is not a bandwidth problem

The robot writes each frame as one burst. A 21.7 KB frame lands in about 24 ms.
A reader that polls every 50 ms can miss the whole burst, and the terminal input
buffer is smaller than a frame, so the kernel discards the tail before anyone
reads it. The decoder then resyncs and the frame is lost entirely.

This is why the companion app appeared to stop seeing faces after the encoder
quality went up: bigger frames, more loss. See camera-performance.md for the
measurements. The fix is to read from a dispatch source that drains as bytes
arrive. **Frame size then stops mattering, and the same code works on a socket.**

Any tool that drains the port continuously with large reads will not reproduce
this, which is exactly why the robot-side benchmarks looked perfect throughout.

## The three ceilings on image quality

Distinguishing these prevents chasing the wrong one.

| Ceiling | Set by | Can it be raised? |
| --- | --- | --- |
| 640×480 of detail | The GC0308 sensor, 0.3 MP | No. Hard cap wherever processing happens |
| Compression artifacts | The ESP32's software JPEG encoder | Yes, by not compressing |
| About 5.2 fps | The deliberately slowed pixel clock | Only by revisiting the tearing fix |

Encode is the ESP32's own wall and it is large: VGA JPEG spends about 498 ms per
frame compressing, which is why VGA runs at 1.9 fps and falls to 1.6 at quality
90. At QVGA the rate is capped by capture instead, which is why bitrate there is
effectively free.

## Moving work to the Mac does not help; this was measured

Shipping raw pixels so the Mac does everything was benchmarked on 2026-09-14:

| Mode | Rate | Payload | Robot prep | USB write |
| --- | --- | --- | --- | --- |
| QVGA JPEG | 3.54 fps | 7.9 KB | 170 ms | 9 ms |
| QVGA raw | 3.50 fps | 153.6 KB | 41 ms | 210 ms |

Offloading the encode saved 129 ms of robot work and spent 201 ms more on the
wire, at 19 times the bytes. Scaled to VGA raw at 614 KB per frame, USB gives
about 1.2 fps, which is **worse** than the 1.9 fps VGA JPEG already manages.

## Where Wi-Fi does and does not help

Wi-Fi is genuinely faster than full-speed USB, but that is not the constraint
today. Remove the wire from the VGA measurement entirely and the rate goes from
1.92 to about 2.0 fps, because the 498 ms encode remains. At QVGA the wire is
9 ms out of 282 ms, and quality 90 uses 76 KB/s against 730–900 KB/s available,
roughly 8% utilised.

**Wi-Fi is transformative for exactly one configuration: uncompressed VGA.**
That removes the encode wall and the bandwidth wall at once, and is the only
path to artifact-free full-sensor images at close to the capture ceiling.

| Path | Rate | Quality |
| --- | --- | --- |
| VGA JPEG over USB | 1.9 fps | Heavily compressed, about 0.5 bits/pixel |
| VGA raw over USB | About 1.2 fps | Lossless |
| VGA raw over Wi-Fi | To be measured | Lossless, full sensor |

Caveats: the ESP32-S3 is 2.4 GHz only, this house runs a crowded mesh, and
throughput there swings with interference. Treat any number as needing
measurement. Jitter will also matter more than throughput once the head is
following a face.

## OTA is already possible; the partition table supports it

Checked on 2026-09-15 by decoding the partition table actually flashed:

| Partition | Offset | Size |
| --- | --- | --- |
| nvs | 0x9000 | 20 KB |
| otadata | 0xe000 | 8 KB |
| app0 | 0x10000 | 3 MB |
| app1 | 0x310000 | 3 MB |
| ffat | 0x610000 | 9.9 MB |

Two application slots plus otadata, and the firmware is about 614 KB, so **no
repartitioning is needed to flash over Wi-Fi.** OTA writes to the inactive slot
and only switches otadata once the image verifies, so a failed transfer leaves
the running firmware untouched.

The residual risk is different: an image that flashes and verifies but then
fails to boot or fails to join Wi-Fi cannot be recovered over the air. The head
USB port is the fallback for that, and the 2026-09-14 full-flash backups are the
floor under it. The project brief's rule still holds — OTA only on top of a
working USB recovery path, which factory restore has now boot-tested.

## Credentials never live in this repo

Wi-Fi credentials belong in NVS on the device, provisioned over the wire, and in
sops on the Mac. `~/dotfiles/secrets.env` already carries other projects'
Wi-Fi credentials under a project prefix; follow that. Never commit an SSID
password, never print one to a log or a transcript, and never echo one back from
the firmware.
