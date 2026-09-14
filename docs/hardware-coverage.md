# Hardware coverage

Requested coverage; exact components and supported functions must be confirmed against official board documentation. Results below distinguish implementation, build/transport validation, and physical validation.

## Build and transport record

2026-09-14 calibration preflight: user confirmed a stable surface and cable slack.
No movement attempted. Read-only UART queries returned -1 for both servos.
Moving the Mini USB cable to the base removed host enumeration; a head power
cycle restored eyes but not base-port USB. Returning the same cable to the head
restored `/dev/cu.usbmodem31201`. An expanded read-only probe then returned base
expander version 65, VM pin direction=input, output latch=0, input level=0.
The base controller is reachable; the low motor-enable signal is consistent
with motor power disabled, but rail voltage was not measured. Both servos still
returned -1 for position, torque, limits, and movement. Controlled power enable
and physical calibration remain pending. No power-enable, torque, mode, EEPROM,
or position writes were made by this diagnostic. Build: 602,599 program bytes,
39,588 static RAM bytes; upload hash verification passed.

User subsequently confirmed the prior face-selection build's highlight stayed
steady and cleared when leaving the frame. Multi-person crossing remains untested.

2026-09-14 face-selection pass: Mini-only geometric selection and temporal
qualification implemented; seven automated tests passed and release app rebuilt.
Live USB preview resumed in the updated app. See [face selection](face-selection.md)
for thresholds and limitations. Physical entry/exit and multiple-person validation
remain pending; no head movement is enabled and no firmware was changed.

Before this app update, the user physically unplugged/reconnected USB. The app
was subsequently inspected showing connected/live video without an agent restart
or Reconnect action, and the user confirmed the eyes remained visible/animated.
This validates one reconnect of that build, not a full battery-off cold start.

2026-09-14 performance pass: instrumented capture wait, image preparation,
USB writes, and eye-present gaps; compared VGA JPEG, QVGA JPEG, and CRC-checked
raw QVGA transport on hardware. Selected QVGA JPEG at a 200 ms minimum interval:
short tests measured 3.54 fps versus the previous 1.34 fps, with zero malformed
complete packets. Raw transfer gave no rate advantage and used about 19 times
the payload. Build: 591,583 program bytes, 34,668 static RAM bytes; upload hash
verification passed. Motion remains absent. See [performance record](camera-performance.md)
for methodology and limitations; physical reconnect/cold-start checks remain pending.
The final-default 30-second run received 105 frames at 3.48 fps with zero
malformed packets. The Mac app displayed the smaller image and a face overlay;
the inspected preview had no visible horizontal slicing. This is one scene,
not a varied-lighting or motion-quality validation. Stop Camera cleared both
the preview and detection indication.
Show Camera subsequently resumed live local frames. The app is left streaming.

2026-09-14 tearing fix: configured GC0308 register `0x28` divider bits `[6:4]`
to `0b010`, preserving the other bits and verifying the register readback before
starting capture. The fixed external 20 MHz clock is unchanged; this slows the
sensor's pixel output instead of only dropping frames at the USB sender.
The first live Mac preview had no visible horizontal slicing and correctly
outlined a face in the current scene. This is a limited visual check, not a
guarantee under all lighting/motion. Build: 589,867 program bytes and 34,604
static RAM bytes; flash hash verification passed. Eyes/motion-lock code was
unchanged. Register reference: Espressif's
[GC0308 driver](https://github.com/espressif/esp32-camera/blob/master/sensors/gc0308.c)
and [register definitions](https://github.com/espressif/esp32-camera/blob/master/sensors/private_include/gc0308_regs.h).

User confirmed the combined-build eyes are visible and animated before this
camera-only adjustment.
Two later previews also showed continuous, unsliced images with face overlays,
including after a Stop Camera / Show Camera cycle. Stopping cleared the preview
and face rectangle; restarting returned to live video. No physical USB removal
or power cycle was part of this particular test.

2026-09-14 combined eyes/camera: moved the existing AGPL eye renderer into a
shared Arduino library and integrated it into `camera_stream`. The eye display
and bounded expression-command parser run independently of the camera task.
Normal remains the default, with 19.2–30 second blink spacing; all eighteen
named poses remain available. No StackChan servo initialization or motor
commands are present. Build: 589,627 program bytes and 34,604 static RAM bytes;
upload hash verification passed. A three-second USB sample contained three
complete JPEG packets with correct start/end markers and no ISR warning text,
plus partial boundary packets from attaching to an ongoing stream. Physical
eye appearance, blink smoothness during video, and expression appearance need
user observation; image tearing is still a separate unresolved issue.

2026-09-14 subsequent physical power cycle: the final transport firmware
returned seven complete JPEG packets in a six-second USB check, with zero
invalid complete packets and zero interleaved ISR warnings. This verifies one
post-power-cycle camera transport session, not sustained image quality or
repeatable cold-start reliability.
The native app was reopened and Show Camera enabled; its UI reported live
local frames and visibly displayed the room. Horizontal image tearing remains
visible, so image quality is not yet accepted. No motion was enabled.

2026-09-14 camera diagnosis: ROM output showed the chip was still waiting for
download after the standard RTS reset. A watchdog reset started the firmware,
which then reported camera initialization failure. Added M5Unified board/power
initialization (without StackChan BSP servo initialization) and released its
I2C bus before the video driver starts. The camera subsequently initialized and
produced JPEG packets. Raw capture also proved ROM ISR overflow warnings could
interleave inside packets, so ROM console channels are disabled in the binary
transport build. This protects framing; camera overruns and image quality remain
separate unresolved performance work. The display now shows camera-startup and
ready/failure status instead of remaining deliberately blank.

Final transport build compiled (575,791 program bytes; 34,116 static RAM bytes)
and uploaded with verification. Following the next watchdog reset, boot output
reported variable partition-table magic/MD5 errors; the cause is not established.
An independent esptool verification of the partition table and application then
matched the build files. Left the device in its loader rather than a reset loop;
a physical normal power cycle is pending. Final-build streaming, cold-start
reliability, and diagnostic-output suppression are therefore **not yet verified**.

2026-09-14: after connecting USB directly to the screen unit and entering
download mode with RST, the Mini enumerated the known Espressif device
`68:EE:8F:D8:4F:04` at `/dev/cu.usbmodem31201`. The pending `camera_stream`
start/stop-handshake build was uploaded successfully with flash verification.
This verifies recovery flashing through that port, not factory restoration.
The temporary build contains no display renderer or motor control; a black
screen is expected. Live camera and physical unplug/reconnect validation of
the repaired companion remain pending for this build.

2026-09-13 companion resilience: the unplug crash was traced to an uncaught
Objective-C exception from `FileHandle.availableData`. The app now uses bounded,
nonblocking POSIX reads/writes and closes the descriptor on disconnect. Tests
using real pseudo-terminals passed for removal during reads, removal before
writes, repeated camera start/stop, and reconnect. Preview and face boxes are
cleared on disconnect or stalled video; results from old detection sessions are
discarded. Physical unplug/reconnect verification of this repair is pending:
StackChan was absent from the Mini's USB enumeration after the reported replug.

| Date | Result | Scope and limitation |
| --- | --- | --- |
| 2026-09-13 | `stanbot` built for ESP32-S3 (588,671 bytes program, 28,852 bytes RAM) and uploaded to `/dev/cu.usbmodem31201`; the flasher verified every written segment by hash. | This confirms the USB flashing path to the attached ESP32-S3 only. It is **not** a display, camera, servo, or other functional hardware test. Motion remains disabled in the uploaded build. |
| 2026-09-13 | Corrected the build target to `esp32:esp32:m5stack_cores3` with QSPI PSRAM. `stanbot` built (544,591 bytes program, 28,820 bytes RAM) and was flashed with per-segment hash verification. | This corrects the board profile used for all subsequent builds. The avatar needs a fresh visual confirmation after this rebuild. |
| 2026-09-13 | `camera_probe` built and flashed with the official StackChan DVP pin map, external 20 MHz camera clock, and CoreS3 QSPI PSRAM profile. It initialized the sensor and returned local 640×480 YUV422 frames. | This is a camera transport test only. The probe does not send images over USB, has not established image quality, and reported capture overruns at the native full frame rate. Face detection is not implemented or verified. |
| 2026-09-13 | `camera_stream` built and flashed with motion absent. It converts local 640×480 YUV frames to bounded JPEG packets over USB. The native Mini app displayed the stream and locally outlined one detected face with macOS Vision. | Verified for the current scene and lighting only, at a conservative ~1.3 fps. This is a face rectangle, not identity or eye-contact detection. No head movement command was sent or enabled. The temporary stream firmware does not display the avatar. |

| Capability | Meaningful hardware test | Implemented | Hardware verified |
| --- | --- | --- | --- |
| Head pan servo | Calibrate safe range and direction; verify smooth bounded motion and stop behavior. | Bounded controller prepared; disabled pending calibration | No |
| Head tilt servo | Calibrate safe range and direction; verify smooth bounded motion and stop behavior. | Bounded controller prepared; disabled pending calibration | No |
| Display | Verify avatar rendering, blinking, and attention states at startup. | AGPL-3.0-or-later M5GFX port companion based on `esp32-eyes`; compiled and flashed. | Base animated renderer: Yes — 2026-09-13. CoreS3-profile rebuild and emotion variants: awaiting fresh visual confirmation; attention state remains untested. |
| Display touch | Verify coordinates and press/release events across the display. | No | No |
| Camera | Capture frames and verify face presence/loss under varied lighting. | Motion-free local `camera_stream` provides bounded USB JPEG frames; the Mini app uses local macOS Vision face rectangles and overlays them on the feed. | Frame transport, live display, and one face rectangle: Yes — 2026-09-13. Varied lighting, target loss behavior, and sustained performance: No. |
| Dual microphones | Verify both channels with known audio and distinguish channel input. | No | No |
| Speaker | Play a known signal at a conservative level and inspect distortion. | No | No |
| Wi-Fi | Verify local connection, reconnect behavior, and operation without internet. | No | No |
| Bluetooth | Verify discovery and an appropriate supported local data exchange. | No | No |
| RGB LEDs | Exercise each LED and channel at bounded brightness. | No | No |
| Battery and power | Compare reported battery/charging state with USB and battery operation. | No | No |
| Proximity / ambient light | Compare readings against known near/far and light/dark conditions. | No | No |
| IMU | Verify stationary gravity and expected response on each movement axis. | No | No |
| Magnetometer | Verify axis response and heading repeatability after calibration. | No | No |
| Head touch | Verify touch and release events with debounce. | No | No |
| NFC | Read a known compatible tag and verify no-tag behavior. | No | No |
| Infrared | Verify supported transmit/receive functions with a known counterpart. | No | No |
| RTC | Set/read time and check retention through supported power transitions. | No | No |
| microSD | Write/read a test file and verify missing-card handling. | No | No |
| Expansion ports | Confirm pinout and electrical limits, then test supported buses with known peripherals. | No | No |
