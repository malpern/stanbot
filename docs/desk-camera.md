# Desk camera: the Studio Display camera alongside the robot's

Design sketch, 2026-09-16. Nothing here is built. The first use is as a
**measuring instrument**: a sharp second view that labels the robot camera's
clips (facing the robot or not), so the robot's own detector can be
calibrated (docs/gaze.md). Wide-view search and fused decisions come later,
if the recordings justify them. The robot keeps working without the desk
camera; everything here is optional.

## Hard requirement: never disturb a Google Meet call

The mini's Studio Display camera is also the video-call camera. The app must be
a **passive second client**:

- **Never reconfigure the device.** No `lockForConfiguration()`: no format,
  frame rate, exposure, zoom or Center Stage changes. On macOS a second
  process can capture a camera another app is using, but any configuration
  change applies to the shared device and so would change what Meet sends.
  Take whatever format is active and downscale in the app.
- **Leave Center Stage to the user.** Queried on this mini: all four formats
  (640x480, 1280x720, 1664x1248, 1920x1080) support Center Stage; it is off, in
  `user` control mode. The app must not switch it. If it is on (for example,
  turned on for a call), panning and cropping make any geometry wrong, so
  frames are marked `center_stage_active` and not used for labels.
- **Know when a call is on.** `isInUseByAnotherApplication` says another
  process holds the camera. Log it with each recording. Optionally pause desk
  processing during calls; that is a setting, not a requirement.
- **Cheap.** Analyse at most 5 fps with Vision on a 1280-wide image, so the
  call's own encoding never competes for CPU. Measure it during a real call.
- **Explicit start.** Desk capture is off until turned on, turns the camera
  light on while running, and shows that in the app. Camera permission is a
  one-time macOS prompt for the Stanbot app.

Unverified until tested with a live call (step 1 below): that Meet's framing,
resolution and frame rate are unchanged while the app captures, in both orders
(app first, Meet first), and with Center Stage toggled mid-call.

## Pieces

1. **DeskCamera** (app): an `AVCaptureSession` on the Studio Display camera,
   with a video data output only. It delivers frames timestamped on the host
   clock (the sample buffer's presentation time mapped to
   `systemUptime`) and never configures the device.
2. **Shared clock.** Robot frames are stamped when they arrive (already
   `receivedAt`), less the measured pipeline delay (~300 ms, from the frame
   sequence numbers the robot already tracks). Matching tolerance: one robot
   frame interval.
3. **Recorder** (app): an explicit Record toggle writes, per session, the
   robot's JPEG frames as they arrive, desk frames downscaled to 1280 px JPEG at
   the analysis rate, and a JSONL index of both with timestamps, Center Stage
   state and whether the camera was in use by another app. Stored under
   `~/Library/Application Support/Stanbot/recordings/`, never in the repo,
   deleted after 14 days unless kept.
4. **Look-at-the-robot calibration** (app, 20 seconds): "look at the robot" for
   5 s, "look at the middle of the screen" for 5 s, "look away" for 5 s, while
   sitting normally. The desk camera's gaze and head direction during each
   prompt give the robot's direction as seen from the desk camera, and how far
   apart robot and screen are in gaze angle for this person at this desk. No
   tape measure, and it is redone if the robot is moved.
5. **Labeller** (tool, offline): for each face the robot camera saw, find the
   same moment in the desk recording; at a desk that is usually one person,
   and with several, match by left-to-right order. Label `toward_robot` when
   the desk camera's gaze direction is within the calibrated cone around the
   robot direction, `toward_screen`, `away`, or `unknown` (face too small,
   Center Stage on, blink, low quality). Output: labels beside the robot
   frames, ready to fit the robot detector's confidence.

## Steps, each useful on its own

1. **Coexistence test (needs you, a Meet call, about 5 minutes).** Built:
   `tools/desk_camera/probe.sh`. Run it from Terminal on a Mac with the Studio
   Display attached (macOS asks Terminal for camera permission the first time):

   ```sh
   tools/desk_camera/probe.sh --watch-only --seconds 30   # device state only; camera stays off
   tools/desk_camera/probe.sh --seconds 120               # passive capture, one JSON line per second
   ```

   It refuses (exit 3) unless a "Studio Display Camera" is attached; which Mac
   it is does not matter. It never locks the device for configuration and saves no frames.
   macOS has no input-priority session preset, so it uses the preset matching
   the camera's current format (640x480, 1280x720 or 1920x1080) and refuses to
   capture if the format is anything else (exit 6), rather than risk switching
   it. Each line reports frames received, frame size, the device's active
   format and frame rate, `in_use_by_another_app` and Center Stage; the last
   says whether the format or rate changed during the run.

   The test: (a) start a Meet call, then the probe; (b) start the probe, then
   join a call; (c) toggle Center Stage in Control Center mid-call. In each,
   watch the self-view (or a second device in the call) for framing,
   resolution or freezes, and note `format_or_rate_changed`. Checked so far,
   without a call: watch-only on the mini (1280x720 at 30 fps, not in use,
   Center Stage off, user control) and the refusal without a Studio Display
   camera. Capture itself has not run yet.
2. **DeskCamera in the app, logging only.** Built, off by default: Settings,
   Desk camera, "Log the Studio Display camera during sessions". It uses the
   same passive rules as the probe (no device configuration, preset matching
   the current format or it does not start; 1664x1248 has no such preset) and
   analyses at most 5 frames a second. During a follow session each analysed
   frame writes a `DESK` line to the session log: time on the same clock as the
   robot frames, every face with its box, confidence, head yaw and pitch and the
   facing class, whether another app is using the camera, and whether Center
   Stage is active. No images are saved. `tools/follow_replay.py` counts DESK
   frames and faces by facing class. Tests: `DeskCameraTests.swift` (preset
   rule, throttle, log line, never opening a camera under tests). Not yet run
   against the real camera; leave it off until step 1 has passed.
3. **Recorder and calibration**, then a first recording session: looking at
   the robot, the screen and away, at two or three distances.
4. **Labeller**, then the comparison that matters: on labelled robot-camera
   faces, does head pose alone, the gaze model, or both predict `toward_robot`,
   and from what face size?
5. Only then decide on wide-view search (turning toward someone the desk
   camera sees) or fusing both cameras live.

## What this cannot do

- Away from this desk there is no desk camera; the robot must not depend on it.
- A label from the desk camera is itself an estimate, around 10 degrees even
  at 1080p. It is far better than the robot's view but is not ground truth; a
  person's own report during calibration is the closest thing to that.
- The screen and the robot are close together in angle when seen from a normal
  sitting distance, so `toward_screen` against `toward_robot` will be the
  hardest distinction, and the calibration exists to measure how hard.
