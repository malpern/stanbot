# Head following

Continuous yaw and tilt toward the selected face. As of 2026-09-15 this is
**groundwork**: compiled into `camera_stream`, exercised by native tests, and
never run on hardware. `C,FOLLOW` refuses to enable motor power until
`stanbot::kFollowLimits.measured` in `firmware/camera_stream/head_tracker.h` is
true, and only the calibration checklist below may set it.

## Why it is not a toggle

The [project brief](project-brief.md) requires calibrated servo limits, smooth
motion, bounded update rates and a safe lost-target behaviour before anything
follows. Three facts from the hardware work make that more than a formality:

- **Tilt has barely moved.** [hardware-coverage.md](hardware-coverage.md)
  records +16 raw (5 degrees) from rest, once. Whether +raw nods up or down is
  unobserved. Tilt carries the head's weight, so a wrong goal falls rather
  than stalls.
- **The servos hunt if asked to.** The
  [servo review](servo-startup-review.md) found `I = 0`: they stop 3-6 raw
  steps short of a goal and never close the gap. A follower that re-issues
  goals to chase that residual oscillates forever.
- **Motor power has been one supervised window per boot.** Following changes
  that from a one-second test to a twenty-second session with frames flowing
  the whole time.

## Design

`head_tracker.h` is pure logic with no Arduino dependencies, tested natively
by `companion/test_head_tracker.cpp` in the same way as `session_guard.h`.

- **Visual servoing, not absolute mapping.** A face at normalized `x = +0.3`
  means "turn a little further right than now", not "point at 30% of travel".
  The camera's field of view is unknown, so `rawPerUnitX/Y` are starting
  gains, not measurements.
- **One goal per observation.** Each accepted `T,` line sets a goal relative
  to the last *commanded* position; ticks step toward it. A frame that arrives
  at 3.5 fps is therefore applied once, not four times by an 80 ms tick.
- **Two deadbands.** A centre deadband on the normalized offset (a face
  already near the middle asks for nothing) and a raw deadband wider than the
  standing error (a residual under 8 raw is accepted as arrived, never
  re-issued). The second is what stops the hunting above; the test
  `rawDeadbandNeverChasesStandingError` pins it.
- **Feedback is not used for control.** The controller tracks what it
  commanded. The firmware reads position only to guard the envelope (limits
  plus a margin) and to detect a stall, exactly as the sweep does.
- **Bounded rate.** At most one goal per `controlPeriodMs` (80), moving at most
  `maxStepRaw` (6, about 23 deg/s) while attending and `restStepRaw` (4) while
  returning. Both are below the 58 deg/s the 2026-09-15 sweep ran smoothly.
- **Lost target.** After `targetTimeoutMs` (900) without an acceptable
  observation the head returns to rest at the slower rate, then goes idle. A
  new face interrupts the return.
- **Session, not mode.** `runFollowSession()` opens the same power window as
  every other motion routine, with a 20 s cutoff armed once and never
  extended. It differs in leaving the stream on, because the host cannot see
  a face without frames. Diagnostics are still held until power is verified
  off.

## Protocol

| Line | Transport | Effect |
| --- | --- | --- |
| `T,<sequence>,<x>,<y>,<confidence>` | USB or TCP | Latest target. `x`/`y` in `[-1, 1]`, `-1` left/top; confidence in `[0, 1]`; sequence strictly increasing. Only consumed inside a session; anything queued before one is discarded as stale. With confidence at least 0.7 it also points the eyes. |
| `G,<x>,<y>` | USB or TCP | Eye gaze only, any time: the drawn pupils look toward that image position. Moves nothing. The app sends one per analysed frame with a selected face while no session runs. |
| `C,FOLLOW` | either | One bounded following session on both servos. Requires the stream on, an unused power window this boot, and measured limits. |
| `C,UNFOLLOW` | either | End the session early with torque off. |

Results arrive after cutoff as `SBPD follow_trace` samples every 40 ms, then
`SBMV {"plan":"follow", "result":..., "observations", "rejected", "yaw_final",
"pitch_final", "yaw_commanded", "pitch_commanded", "mode"}` and the usual
`SBPW` power summary. Results: `follow_refused_limits_unmeasured`,
`requires_unused_boot`, `follow_requires_stream_on`, `preflight_refused`,
`hold_goal_unverified`, `torque_enable_unverified`, `session_complete`,
`session_deadline`, `stopped_by_host`, `cutoff_before_completion`,
`goal_write_failed`, `position_status_error`, `feedback_outside_envelope`,
`stall_detected`.

## Session 1, 2026-09-15: what was measured and what broke

Supervised, at Hacker Dojo, with synthetic `T,` targets typed from the host
rather than real detections, and narrowed limits in a throwaway calibration
build that set `measured` true. Three results are settled:

- **Yaw `+raw` turns the head to the robot's right.** The operator reported
  "left" from their own side of the robot, which is the robot's right; the
  question was asked explicitly because the two readings are opposite and a
  wrong sign makes the head flee the face.
- **Pitch `+raw` tilts the head up.** `pitchUpSign = +1` confirmed.
- **The image is not mirrored.** A frame captured with the operator standing
  on the robot's right put them on the right of the image, so `observe()`'s x
  sign is right as written. Checked by looking at a frame, not by reasoning
  about the sensor.

Pitch rest is still unknown: 642 was reported as tilted up, so level is at or
below it, and 620 (the BSP's 0 degrees) was never reached to be judged.

### The session never completed, and the reasons are design defects

- **`goal_write_failed` after 9-27 servo commands, twice.** `serviceFrame()`
  was called every loop iteration, and `captureBuffer()` blocks on the sensor,
  so the control loop ran 17 times where 165 were due. It now captures only
  when a frame is actually due, and the bus timeout is 60 ms inside a session
  rather than the 20 ms the tight sweep loop can assume. Neither fix is
  verified: the session that followed refused at preflight with both servos
  reading -1, which is a third failure mode, not a pass.
- **Diagnostics are corrupted by the frames.** This is the deeper problem. The
  USB protocol carries binary `SBFR` packets and newline-delimited text on one
  channel, and every other motion routine keeps them apart by refusing to run
  while the stream is on. Following cannot do that - without frames there are
  no faces - so text lines and packets interleave, and a reader splitting on
  newlines shreds them. A host demultiplexer helps but does not fix it: the
  text has no framing of its own. Either diagnostics need a packet type, or a
  session's telemetry must be buffered and emitted with the stream stopped.
- **A "yaw-only" session moved pitch.** Return-to-rest drives both axes, so
  while pitch sat away from its rest value every lost target pulled it. Across
  two sessions the head was tilted about 16 degrees on the least validated
  axis without anyone deciding to. The preflight checks where the head starts,
  not where the controller may ask it to go.

The robot was verified healthy afterwards with `C,POWERTEST`: both servos
answer, torque off, limits 20/1003, gains p15 d15 i0 unchanged, and the head
was recentred with `C,CENTER`.

## Ready for session 2, 2026-09-16

Everything that does not need the head to move is now in place.

- **Yaw only.** `kFollowPitchEnabled` is false. The tracker never commands,
  clamps or returns pitch, and the session never writes a goal or enables
  torque on servo 2; it only reads pitch and aborts with
  `feedback_outside_envelope` if the unpowered head moves more than 16 raw from
  where it started. This closes the defect where a "yaw-only" session tilted
  the head 16 degrees. `pitchDisabledNeverMovesPitch` in
  `companion/test_head_tracker.cpp` pins it and fails against the old
  return-to-rest code. Preflight still requires pitch to answer.
- **Calibration builds without editing source.** `STANBOT_FOLLOW_CALIBRATION=1
  firmware/build.sh` builds limits of centre +-48 yaw with `measured` true, from
  a committed tree. `V` then reports `follow_limits_measured:true`, the app's
  Firmware card turns orange, and `build_info.json` records
  `"follow_calibration": true`.
- **The companion sends targets (checklist step 5).** Head following in the app
  starts a session over USB only (`C,FOLLOW` is USB-only on the Wi-Fi
  allowlist), after a confirmation, and then sends one `T,` line per analysed
  frame for the face the selection logic has confirmed, sequence from 1. Stop
  sends `C,UNFOLLOW`. The robot's `SBMV` result, or an `SBPW` refusal, ends the
  session in the app; `requires_unused_boot` offers Reboot Robot (`C,REBOOT`).
  Vision coordinates convert to the robot's convention: x = 2·midX − 1,
  y = 1 − 2·midY.

**Before the session, the operator should know:**

1. Use Settings → USB only, cable in the side (head) port. Quit and reopen
   nothing else on the serial port.
2. Yaw must rest between 412 and 508 raw or preflight refuses
   (`preflight_refused`). Unpowered servos read -1 over `Q`, so position is only
   known inside a power window; `C,CENTER` recentres yaw if needed, then
   `C,REBOOT` frees the window again.
3. Still unverified from session 1: the `goal_write_failed` fixes, and why
   preflight once read both servos as -1.
4. Control runs on the camera task, so a tick waits behind capture and encoding
   (about 135 ms a frame). Motion will be slower than `maxStepRaw` suggests,
   which is acceptable for a first session and worth measuring from the trace.

## Session 2, 2026-09-16: it follows

Supervised at home, operator in front of the robot, calibration build 27092a9
(yaw centre +-48, pitch unpowered), started from the app over USB with real
face detections. Log: `~/Library/Logs/Stanbot/follow-20260916-153339.log`.

**Result `session_deadline`: the full 20 s, and the head turned toward the
operator** (reported by the operator, and in the trace). Settled from session 1:

- **No `goal_write_failed`** in 28 position commands, and **no preflight
  refusal**: yaw started at 446, pitch at 601, both answering, torque off.
- **Pitch stayed put:** 601 to 603 unpowered across the session.
- **No hunting:** 27 commanded moves with one direction reversal; the gap
  between commanded and actual yaw had median 0 and maximum 12 raw.

What the trace shows:

| Time | Yaw commanded / actual | Mode |
| --- | --- | --- |
| 1.0 s | 446 / 446 | idle |
| 3.3 s | 506 / 496 | attending, at the +48 limit |
| 5.5 s | 498 / 503 | returning (target lost) |
| 7.8-17.0 s | 466 / 466 | idle, no targets |
| 19.4 s | 424 / 434 | attending, turning the other way |

**Open problems, in order of effect:**

1. **Targets were sparse:** 21 observations in 20 s, with a 10 s stretch of
   none. Unknown whether the face left the frame at the yaw limit, or the app's
   selection dropped out of "Face selected" while the head moved. Needs app-side
   logging of what was detected versus sent.
2. **Motion is slow:** the loop ran every ~192 ms (97 iterations; worst 295 ms)
   because each iteration waits for a camera frame, so a 6-raw step lands about
   five times a second, roughly 10 degrees per second.
3. **The +-48 limit was reached within 2.5 s.** Step 4 (widen) is next once
   1-2 are understood.
4. **One byte was lost on USB in the telemetry**: the result line arrived as
   `yaw_fnal`. The firmware prints `yaw_final`. Rare, but telemetry is not yet
   trustworthy byte for byte. (Now detected: see Telemetry integrity.)

## Sessions 3-5, 2026-09-16: faster, steadier, then no overshoot

Recorded from the commit messages of that afternoon; the logs are in
`~/Library/Logs/Stanbot/`.

- **Session 3 (768e540):** capture moved to its own task, so the control loop
  ticked every ~7 ms (worst 20) instead of ~192 ms, turning at up to ~21 deg/s.
  Targets rose from 21 to 36, but the face lock still dropped in 94 of 98
  frames; the match gate got a floor of 0.2 of the frame (2bbb39b).
- **Session 4:** a face high in the frame was rejected for 3.5 s because its
  box ran past the top edge. Boxes are now clipped to the frame (c9237f4).
- **Session 5:** the head hunted across its whole range, about a 3 s period.
  Targets now carry the frame's sequence number and the correction is applied
  relative to where the head was when that frame was sent, at 0.6 gain
  (136488b). **A later supervised test confirmed the overshoot is gone.**

Session 2's open problems 1 (sparse targets) and 2 (slow motion) are
addressed; 3 (the +-48 limit) and 4 (a lost telemetry byte) remain.

## Pitch following (built, not yet run on the robot)

Up and down now follows the same way as left and right, in a build made with
`STANBOT_FOLLOW_PITCH=1 firmware/build.sh` (add `STANBOT_FOLLOW_CALIBRATION=1`
for the narrowed first session). The normal build is still yaw only. The robot
reports `follow_pitch` in `V`, `build_info.json` records it, `ota.py` checks it,
and the app lists it as a Firmware warning.

Because no pitch rest has been confirmed by eye, pitch is bounded **relative to
where each session finds the head** rather than to a fixed rest:

- **Up:** at most `pitchUpTravel` above the start (16 raw, 5 degrees, in the
  calibration build; 32 otherwise), and never above `pitchMax` (672).
- **Down:** no lower than the lower of the start and 620 (the BSP's 0
  degrees). A head resting at 601, as in session 2, is never pressed lower; one
  resting tilted up at 640 may come down to 620.
- **Start:** preflight accepts a pitch between 596 (620 less
  `pitchStartSlack`) and 672. Unpowered rests seen so far: 601, 620, 621, 639,
  640.
- **Lost target:** pitch returns to where the session started, not to
  `pitchRest`, until `pitchRestConfirmed` is set.
- **Delay:** pitch uses the same frame-time compensation as yaw, since without
  it yaw hunted in session 5.
- **Envelope:** the firmware aborts if pitch feedback leaves this session's
  bounds by more than 16 raw.

Host tests in `companion/test_head_tracker.cpp` cover following up and down, the
travel bound, a low rest never pressed lower, the return to the start, start
acceptance, and a closed loop with 300 ms of delay on pitch alone and on both
axes. Simulated with compensation, pitch settles 10 raw short of the face with
no reversals; without it, it overshoots once and travels 60% further. Both
firmware variants compile. **Nothing about pitch following has run on the
robot.**

First supervised pitch session: flash a calibration + pitch build, stand so
your face is above the camera's centre, and confirm the head tilts up and
returns to where it started when you step away.

## Searching for a lost face (built, not yet run on the robot)

When no target arrives for 900 ms the head no longer goes straight home. The
tracker enters `Searching` (telemetry `mode` 3):

1. **Hold** still for 600 ms, since the face may only have been missed.
2. **Glance** 32 raw toward the side of the frame the face was last seen on,
   and 12 raw up or down if it left off the top or bottom (pitch builds only,
   inside the session's pitch bounds). If the face was last seen near the
   centre, the first move is 32 raw to the robot's right.
3. **Sweep** to 32 raw the other side of where it was lost.
4. **Return** to rest (pitch to the session start) as before.

It dwells 400 ms at each waypoint and moves at 3 raw per tick (~11 deg/s),
slower than attending. Every waypoint is clamped to the limits. Any accepted
target ends the search immediately. A whole search takes about 4.6 s from the
last target to resting, well inside the 12 s a session waits without a face. The app's "No stable face
detected" state is still only a label; auto-follow still starts a session only
once a face is confirmed. Host tests: `searchHoldsThenGlancesTowardTheLostSide`,
`searchStartsLeftWhenTheFaceLeftLeft`, `searchEndsWhenTheFaceReturns`,
`searchGlancesUpForAFaceLostOffTheTop`, `searchNeverMovesDisabledPitch`,
`searchIsClampedAndFinite`.

## Continuous following (built, not yet run on the robot)

Sessions used to end every 20 s, followed by a 3 s cooldown the app waited
out. Now the motor-power cutoff is a **lease** (`power_lease.h`):

- The cutoff task removes power when the lease (20 s) runs out without
  renewal, or at a hard maximum (3 minutes) armed when the window opens and
  never extended, whichever is first. It still never waits on USB, camera or
  the servo bus.
- The follow loop renews the lease once a second, but only while it has
  accepted a target within the last 12 s. A hung, starved or target-less loop
  stops renewing, and power goes off within one lease: the same bound the fixed
  20 s deadline gave.
- The session ends itself 500 ms before either limit, and after 12 s with no
  accepted target (`session_idle`), so the orderly path, not the watchdog,
  normally removes power. New results: `session_idle` and
  `session_max_duration`; `session_deadline` now means the lease was about to
  lapse. The app restarts after all three.
- Every other power window (sweeps, nudges, power tests) passes no maximum and
  is never renewed, so its cutoff is exactly the fixed deadline it was.
- The trace keeps spanning the whole session: when its 400 samples fill, every
  other one is dropped and the sampling stride doubles. `SBFL` now reports
  `renewals`, `trace_stride` and `session_ms`.

`companion/test_power_lease.cpp` covers the unrenewed deadline, renewal, the
cap, a renewal read racing the cutoff, `millis()` wrap, idle and maximum
endings, and a simulated loop that renews forever and still ends at 179.5 s
with the lease never lapsing first. What it cannot show is the servo and
supply behaviour over three minutes of torque; watch temperature and voltage
in the first long session.

## Telemetry integrity (built, not yet run on the robot)

Session 2 lost one byte on USB, and the damaged result (`yaw_fnal`) still
looked like valid JSON. `SBTE` now carries `lines` and `crc32`: the number of
lines in the block and a CRC-32 (IEEE, the same as `zlib.crc32`) over their
bytes with line terminators removed (`telemetry_check.h`). The app checks each
block and writes `APP {"telemetry_check":"verified"|"corrupted"|"unchecked"}`
to the session log, and says so when a block is damaged, since its numbers are
then not evidence. `sbstream.telemetry_check()` does the same in Python.
A line the host's decoder rejects also counts as damage, because the line count
no longer matches. Firmware older than this sends a bare `SBTE`, reported as
unchecked. Shared test vector: two lines, `76f85edc`, in
`test_telemetry_check.cpp`, `TelemetryCheckTests.swift` and `test_sbstream.py`.

This detects damage; it does not repair it. The lost byte itself is still
unexplained.

## Eyes glance at the face (built, not yet seen on the robot)

The drawn eyes now look toward the selected face: from `T,` lines during a
session and from `G,` lines otherwise. Their smoothing (14% of the remaining
distance per 33 ms frame) is much faster than the head, so the eyes lead and
the head follows. `eye_gaze.h` mirrors x, because the display faces the
person: someone on the robot's right is on the image's right but the screen's
left. That mirror is reasoned from the measured image orientation and needs a
look on the robot. With no gaze for 900 ms the eyes drift back to idle.
Tested by `companion/test_eye_gaze.cpp` and `test_network_policy.cpp`.

## Easing (built, not yet run on the robot)

Moves used to be a fixed 6 raw per tick from the first tick to the last. Each
tick now moves 40% of the remaining distance, at least 2 raw, never more than
the old step limit, and at most 2 raw more than the previous tick in the same
direction. A long move therefore starts at 2, ramps to 6 and slows into the
goal; a reversal starts again from 2. Nothing is faster than before, and the
closed-loop simulations (compensated yaw, pitch and both axes) still settle
without crossing the centre. Tests that count exact ticks use a linear
configuration (`kLinear`), and `easingRampsUpAndSlowsDown` pins the new shape.

## Calibration checklist, before `measured` may become true

Each step is one supervised session with a person at the robot, the cable in
the head port, and the stream on. Record the numbers in `head_tracker.h`.

1. **Yaw direction.** With `yawMin/yawMax` narrowed to centre +-48, hold a face
   left of frame and confirm the head turns robot-left. If it turns away,
   the image is mirrored relative to the assumption in `observe()` and the
   sign of `rawPerUnitX` must flip.
2. **Pitch direction.** Same session, face high in frame, `pitchMax` at rest
   +32. Observe nod up or down; record `pitchUpSign`. If +raw nods *down*,
   the safe range is on the other side of rest and both pitch limits change.
3. **Gains.** With directions right, check the head settles on a still face
   without oscillating. If it hunts, the deadbands are too narrow for this
   unit's standing error; if it lags, raise `rawPerUnitX/Y` a little.
4. **Widen.** Extend the limits toward what the sweep traversed (yaw +-288),
   one session per step, watching for the head meeting the body. No source
   edit is needed: `STANBOT_FOLLOW_CALIBRATION=1 STANBOT_FOLLOW_YAW_RANGE=96
   firmware/build.sh`, then 144, 192, 240 and 288. Other values fail to
   compile, V reports `follow_yaw_range`, and `ota.py` checks it.
5. **Companion.** Done: the app sends `T,` targets with the frame's sequence
   number (sessions 2-5).

Only after 1-4 have been run on this unit and written down does `measured`
become true. Until then the command exists so that everything around it can
be reviewed, compiled and tested without anything being able to move.
