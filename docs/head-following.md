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
| `T,<sequence>,<x>,<y>,<confidence>` | USB or TCP | Latest target. `x`/`y` in `[-1, 1]`, `-1` left/top; confidence in `[0, 1]`; sequence strictly increasing. Only consumed inside a session; anything queued before one is discarded as stale. |
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
   one session per step, watching for the head meeting the body.
5. **Companion.** The app computes a selected face but sends no `T,` lines
   yet. That is the remaining software step; it belongs after 1-2 so the
   first targets are sent into a controller whose signs are known.

Only after 1-4 have been run on this unit and written down does `measured`
become true. Until then the command exists so that everything around it can
be reviewed, compiled and tested without anything being able to move.
