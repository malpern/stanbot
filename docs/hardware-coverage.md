# Hardware coverage

Requested coverage; exact components and supported functions must be confirmed against official board documentation. All implementation and physical validation are pending.

## Build and transport record

| Date | Result | Scope and limitation |
| --- | --- | --- |
| 2026-09-13 | `stanbot` built for ESP32-S3 (588,671 bytes program, 28,852 bytes RAM) and uploaded to `/dev/cu.usbmodem31201`; the flasher verified every written segment by hash. | This confirms the USB flashing path to the attached ESP32-S3 only. It is **not** a display, camera, servo, or other functional hardware test. Motion remains disabled in the uploaded build. |

| Capability | Meaningful hardware test | Implemented | Hardware verified |
| --- | --- | --- | --- |
| Head pan servo | Calibrate safe range and direction; verify smooth bounded motion and stop behavior. | Bounded controller prepared; disabled pending calibration | No |
| Head tilt servo | Calibrate safe range and direction; verify smooth bounded motion and stop behavior. | Bounded controller prepared; disabled pending calibration | No |
| Display | Verify avatar rendering, blinking, and attention states at startup. | Avatar implementation prepared | No |
| Display touch | Verify coordinates and press/release events across the display. | No | No |
| Camera | Capture frames and verify face presence/loss under varied lighting. | ESP-WHO integration design prepared; no capture or detection build yet | No |
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
