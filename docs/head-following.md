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
| `G,<x>,<y>[,<engaged>]` | USB or TCP | Eye gaze only, any time: the drawn eyes attend to that image position. `engaged` 1 means the person faces the robot: the eyes lock on and the pupils dilate; 0 or absent, they mostly look away with occasional glances (GazeBrain.h). Moves nothing. The app sends one per analysed frame with a selected face, during sessions too. |
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

## Pitch following (running on the robot since 2026-09-17)

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

## Searching for a lost face (running on the robot; seen in session traces as mode 3)

When no target arrives for 900 ms the head no longer goes straight home. The
tracker enters `Searching` (telemetry `mode` 3) and hunts in two stages, cheap
first:

1. **Hold** still for 600 ms, since the face may only have been missed.
2. **Glance** 32 raw toward the side of the frame they were last seen on, and
   12 raw up or down if they left off the top or bottom (pitch builds only).
3. **Glance** 32 raw the other way.
4. **The far side they went**: all the way out to that yaw limit.
5. **The other side**: all the way out to the opposite limit.
6. **Up** at rest, then **down** at rest.
7. **Return** to rest, and only then does the session's 12 s clock start.

Any accepted observation ends it wherever it has got to, so someone who leaned
out of frame and back is found in the first couple of seconds and the head
barely moves; the whole-range look is what happens when that fails. Steps 4-6
are `layOutLookAround`, shared with the wake scan, which skips the glances
because nobody has been lost. The two still differ only in the reaction on
finding someone, which stays the wake scan's. It dwells 400 ms at each waypoint
and moves at `scanStepRaw` 10 raw per tick (~39 deg/s, well under the 58 the
2026-09-15 sweep ran smoothly at). Every waypoint is clamped to the limits.

**The shape came in two steps on 2026-09-17.** It was a glance and nothing
more: 32 raw each way, which at the old +-96 limits was most of the range, and
at +-288 is a twitch -- the head was back at centre while the person stood two
feet outside the frame. The owner asked for the full look ("I expect it to do
the full scan when it loses me. Only if it can't find me should it go back to
center and rest"), and then, seeing it, for both ("I like the idea of a glance
vs a full look around").

**It is no longer well inside the idle timeout, and that matters.** At the
limits now on the robot (yaw 143..719) a whole search takes **14.3 s** from the
last target to resting, and the wake scan 12.9 s. `kFollowIdleEndMs` is 12 s,
so the session would have ended mid-sweep; the loop holds that clock while
`tracker.lookingAround()`, which is true for a search as well as a wake scan,
so the 12 s is 12 s of *resting* after the look has finished. Host tests:
`searchGlancesFirstThenLooksAroundEverything`, `aGlanceIsOftenTheWholeSearch`,
`searchStartsLeftWhenTheFaceLeftLeft`, `searchEndsWhenTheFaceReturns`,
`searchLooksUpAndDown`, `searchNeverMovesDisabledPitch`,
`searchIsClampedAndFinite`.

## Looking around with nobody to lose (a wake, or a reboot)

`beginScan` is the look around for a robot that has not lost anybody: it has
just woken, or just come back from a reboot. It **starts where someone was last
seen**, if this boot has seen anyone, and carries on outward from that side
rather than crossing the room first; then the ordinary look around, then home.
The owner asked for it on 2026-09-17, having watched a scan sweep past where
they were sitting: "Remember where I was last time and start the search in that
general area. Only if that fails, then do a full scan search."

The remembered place is where the head would have had to point to look straight
at the last accepted observation. `HeadTracker` records it, the sketch carries
it from session to session in RAM, and the **Mac** keeps it across a reset: the
robot reports it in `SBMV` (`last_seen_yaw`, `last_seen_pitch`) and the app
hands it back on connecting. With nothing remembered at all the sweep starts
robot-left as before.

### State that survives a reset

Three kinds, in three places, and the distinction is worth keeping:

| kind | where | why |
|---|---|---|
| Measured constants: the yaw centre, pitch level, the limits | firmware source, in git | they are findings, and belong in history and review, not in a runtime store |
| What the robot needs with nobody there: Wi-Fi profiles, the OTA passphrase | the robot's NVS | it has to work with no Mac present |
| Guesses and preferences: where someone was last seen | **the Mac** (`RobotState`, UserDefaults) | see below |

Last-seen lived in NVS for an hour on 2026-09-17 and was moved out deliberately.
A value the robot keeps to itself cannot be shown, diffed or cleared from here,
and a stale one that quietly biases where the head looks is exactly the kind of
bug that eats an afternoon -- in a project being actively developed, where the
robot is reflashed many times a day and the Mac is not. On the Mac it can be
printed into the session log, reset, and tested with no robot present, and it
survives a full erase or a replacement CoreS3, which NVS does not. (NVS itself
survives an OTA: `espota` writes only the app partition. That was never the
problem.)

**The mechanism** is one command, `K,key=value,...`, sent on every version
report -- once per connection, so a robot that rebooted mid-session is caught
too. Keys are an allowlist and unknown ones are ignored at both ends, so an
older robot and a newer app tolerate each other. Every value is clamped to the
follow limits on arrival; nothing here moves anything, it only biases where a
look around begins. The robot answers `SBRS` with what it actually took, so the
session log shows the value rather than the app's belief having to be trusted.
It is allowed over Wi-Fi (`network_policy.h`) for that reason.

Adding another carried value costs one key in `RobotState` and one `else if` in
`applyRestore`.

## Eyes first, then the head

A follow session is what moves the head, and the robot will not begin one while
its face is not yet there: `loop()` holds `followRequested` until the boot
screen has handed over **and** `eyes.eyesOpen()` says the lids are all the way
up. The request is not dropped, it waits. The app holds its side too: nothing
starts while its own waking sequence is running (`appIsWaking`, 2.4 s).

Asked for on 2026-09-17, watching a reboot: the look around began while the
network boot screen was still up, so the head swung with no eyes to see it
with. "I'd like the eyes to open first (on the device and stanbot) and only
then start moving the head."


**The reboot's own look around** takes two agreeing halves, and they have to
agree or the head powers up and does nothing for 12 s:

- The robot looks around on the **first session after a boot**
  (`scanOnFirstSession`, consumed once), as well as within 20 s of a `C,WAKE`.
- The app **asks for that session**. A session is what powers the head, and the
  app starts one only for a confirmed face, within 12 s of a wake, or while the
  robot says it still owes a look around (`AutoFollow.shouldStart`). Reconnecting
  to a robot that has been up for hours and already scanned buys nothing.

**Do not gate this on a clock -- it was, twice, and both failed the same way.**
The first version asked only within 30 s of the reported `uptime_ms`, and held
the allowance for 12 s after that. A flash, its verification and the sleep/wake
base check take 60-90 s before the app is reopened, so the robot was always
"up too long" by the time anything connected, and it came back from every flash
and sat perfectly still. A stopwatch here cannot agree with one there. The robot
now reports **`scan_pending`** in `V` -- it knows whether it has run a session
since booting -- and the app asks on that, with no window at all; the allowance
stands until the session is actually requested, because the camera can take
longer to come up than any window worth choosing. `uptime_ms` remains as the
fallback for firmware that predates the field.

Before this, a just-flashed robot sat perfectly still with nobody in view,
however long it waited, because nothing had been lost and so nothing searched.

**A reboot waits for the session, and used to wait silently.** `C,REBOOT` sets
a flag the main loop acts on, and the main loop cannot reach it while
`runFollowSession()` is running -- which, now that following is continuous, is
most of the time, and for up to the three minute cap. On 2026-09-17 the owner
chose Reboot Robot and "it didn't seem to do anything"; it happened two minutes
later. The session now ends itself when a reboot is pending
(`stopped_for_reboot`, a normal ending, so no trouble face), and `SBRB` goes
through `Telemetry` rather than `Serial` alone, which over Wi-Fi was silence.

That ending is deliberately **not** retryable, so nothing shouts `C,FOLLOW` at a
robot that is restarting -- and because it is not, the app clears a finished
session when it sees a new boot, or the reboot's own look around would never
start.

**A reset is a small sequence, not a snap** (asked for 2026-09-17), and it is
the same sequence for the Reboot command and for a firmware update -- the owner
said "or whenever the robot is being reset", and an update restarts through
espota's own path, which never touches `rebootRequested` at all:

1. **Home.** The session sees the pending reboot and returns the head to centre
   while it still has motor power, rather than freezing mid-turn and coming back
   facing the wall. `HeadTracker::atRest()` says when it has arrived; 800 ms in
   the native test, and the reset waits at most `kRebootCentreMs` (2.5 s).
2. **Eyes.** The session ends, and the lids close as they do for sleep
   (`eyes.beginSleep`), at most `kRebootEyesMs` (1.2 s).
3. **Restart**, after a 700 ms drain.

Every step is bounded, in both directions: a head that cannot get home and lids
that never report closed must not be able to prevent a reboot.

For an update the same two steps happen inside `ArduinoOTA.onStart`: the
session ends `stopped_for_update` once the head is home, and the lids are then
closed and **drawn right there**, because that handler runs ON the loop task and
`loop()` is not going round to animate them.

**That drain is not padding.** At 100 ms the last two lines of a 256-line
telemetry block were lost on 2026-09-17 and the app called the session
corrupted -- a restart racing its own report. The session's numbers were fine;
only the ending was.

**One more trap the same reboot exposed.** Authorizing a reboot sets the app's
follow state to `.idle` at once, so the session that ends *because* of that
reboot reports its result to an app that is no longer following -- and the
`case .following` guard in `handleLine` dropped the whole line. The robot had
learned the owner was at yaw 518 and the app threw it away. The remembered
place is now read before that guard: it is worth keeping whatever the session
state was.

## The light bar (running on the robot; `light_bar.h`)

The twelve LEDs say what the robot is doing about you, which is otherwise only
legible from the head's motion:

| state | colour | when |
|---|---|---|
| Face | soft blue, steady | a face is attended to, held 1.5 s past the last one |
| Looking | orange, pulsing every 900 ms | the head is looking around for someone (tracker mode 3: a search or a wake scan) |
| Lost | dim purple, steady | the camera is streaming and nobody has been found |
| Off | dark | nobody is watching through the camera, or the robot is asleep |

The orange was a single 5 s breath meaning "streaming, no face", which covered
looking and not-finding at once. The owner asked for them apart on 2026-09-17:
"different colors for looking for you (pulsing orange rapidly), and can't find
you (dark purple)."

**The service rate follows the state, deliberately.** The bar is serviced every
125 ms, which is seven samples of a 900 ms pulse and visibly steps (0.36 of the
brightness range per step). While Looking it is serviced every 50 ms instead
(0.15 per step). That is extra traffic on the bus the camera and motor power
share -- the bus whose ownership caused the 2026-09-17 outage -- so it is
bounded to the one state that needs it, which lasts about 13 s. A write still
happens only when the colour actually changes.

`headLookingAround` carries the tracker's state from the session loop to
`serviceLightBar`, which also runs outside a session; it is cleared in the
session teardown, or the bar would pulse orange long after the head stopped.

## Continuous following (running on the robot since 2026-09-17)

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

## Telemetry integrity (running: every session log carries its check)

Session 2 lost one byte on USB, and the damaged result (`yaw_fnal`) still
looked like valid JSON. `SBTE` now carries `lines` and `crc32`: the number of
lines in the block and a CRC-32 (IEEE, the same as `zlib.crc32`) over their
bytes with line terminators removed (`telemetry_check.h`). The app checks each
block and writes `APP {"telemetry_check":"verified"|"corrupted"|"unchecked"}`
to the session log, and says so when a block is damaged, since its numbers are
then not evidence. `sbstream.telemetry_check()` does the same in Python.
A line the host's decoder rejects also counts as damage, because the line count
no longer matches. Hosts count only `SBPD`, `SBMV`, `SBFL` and `SBPW` lines, since
replies from another firmware task (`SBWF`, `SBNR`) can land between the markers
and are not part of the checksum. Firmware older than this sends a bare `SBTE`, reported as
unchecked. Shared test vector: two lines, `76f85edc`, in
`test_telemetry_check.cpp`, `TelemetryCheckTests.swift` and `test_sbstream.py`.

This detects damage; it does not repair it. The lost byte itself is still
unexplained.

Found while building this: the app's decoder dropped every line ending in
`\r\n`, which is what `Serial.println()` writes, because it required the line
to end in `}`. `SBTB`, and refusals such as `follow_requires_stream_on`, never
reached the app or the session logs. The decoder now drops a trailing `\r`
(`testCarriageReturnLinesAreKept`).

## Eyes glance at the face (built, not yet seen on the robot)

The drawn eyes now look toward the selected face: from `T,` lines during a
session and from `G,` lines otherwise. Their smoothing (14% of the remaining
distance per 33 ms frame) is much faster than the head, so the eyes lead and
the head follows. `eye_gaze.h` mirrors x, because the display faces the
person: someone on the robot's right is on the image's right but the screen's
left. That mirror is reasoned from the measured image orientation and needs a
look on the robot. With no gaze for 900 ms the eyes drift back to idle.
Tested by `companion/test_eye_gaze.cpp` and `test_network_policy.cpp`.

## Easing (in use on the robot; never judged on its own)

Moves used to be a fixed 6 raw per tick from the first tick to the last. Each
tick now moves 40% of the remaining distance, at least 2 raw, never more than
the old step limit, and at most 2 raw more than the previous tick in the same
direction. A long move therefore starts at 2, ramps to 6 and slows into the
goal; a reversal starts again from 2. Nothing is faster than before, and the
closed-loop simulations (compensated yaw, pitch and both axes) still settle
without crossing the centre. Tests that count exact ticks use a linear
configuration (`kLinear`), and `easingRampsUpAndSlowsDown` pins the new shape.

## Following over Wi-Fi only

Everything needed to follow with the USB cable in the power-only back port is
built; none of it has run that way on the robot. Before the first such session:

1. **Update safety (new, revised after review).** Every motion routine
   (following, sweeps, nudges, pitch level, power tests) holds a
   `MotionGuard` from before its power window opens until its telemetry is
   written. An OTA update asks motion to stop (`stopped_for_update`), waits up
   to 25 s for the guard to clear, and only then has the camera task, which
   owns the viewer socket, close it. No routine starts while an update is in
   progress (`update_in_progress`). The first version waited only on follow
   sessions, for 3 s, cleared its flag before the telemetry dump, and closed
   the socket from the loop task while the camera task was still writing to
   it. Known gaps: if the wait runs out, or power-off was not verified, the
   update still proceeds (the routine's own cutoff bounds power); nothing
   drives the motor enable low at boot after a software restart.
2. **Link loss.** If Wi-Fi drops mid-session no targets arrive, the lease
   stops being renewed, the head searches and returns, and the session ends
   after 12 s (`session_idle`), power off. Nothing depends on the app
   reconnecting.
3. **Authorization.** Follow and Reboot need the passphrase challenge
   (`command_auth.h`); Stop, eye gaze (`G,`) and targets do not.
4. **Telemetry** reaches the Wi-Fi viewer and is checked the same way.
5. **Checklist for the session:** flash over OTA with the app closed
   (`firmware/ota.py`), move the cable to the back port, open the app on
   Wi-Fi, confirm the Firmware card shows the expected commit, stay at the
   robot, and replay the log afterwards.

## Replaying a session

```sh
python3 tools/follow_replay.py ~/Library/Logs/Stanbot/follow-YYYYMMDD-HHMMSS.log         # writes .html beside it
python3 tools/follow_replay.py ~/Library/Logs/Stanbot/follow-YYYYMMDD-HHMMSS.log --json  # summary only
```

One self-contained page per log: commanded and measured yaw and pitch against
time, shaded by tracker mode (idle, attending, returning, searching); the
face's offset from the frame centre with the targets that were sent; and a
summary of the result, the telemetry check, targets sent, error median and
maximum, range and reversals per axis, and time in each mode. Robot and app
clocks are aligned only approximately (the first APP line is time zero).
`tools/test_follow_replay.py` checks it on a synthetic log; it also runs on
every log from 2026-09-16. The app's APP lines now include the target's `y`.

On session 5's successor (`follow-20260916-165311.log`) it shows yaw holding at
~499 against a 506 goal with the face still 0.28 right of centre for 16 s: the
head was at the calibration build's +48 limit, which is checklist step 4.

## Pitch level found, 2026-09-17

`companion/find_pitch_level.py`, operator at the robot on USB: raw 634 was
tilted up, 614 level (`calibration-pitch-level.jsonl`). The first attempt that
morning stopped with DISABLE LATCH NOT VERIFIED: Stanbot was open on Wi-Fi
with automatic following on and had started a session, so the robot never ran
the level move or reported power off. The robot was power-cycled by hand, and
the finder now refuses to run while the app is open.

Limits from 614 (both builds): pitch 598..646 (level -16 to +32), rest 614,
`pitchRestConfirmed` true, so a lost face returns pitch to level rather than to
where the session started. The unpowered head droops to 594, below the down
limit; a session starting there may rise to 646 but never goes below 594.
Flashed together with yaw widened to +-96 (`STANBOT_FOLLOW_YAW_RANGE=96`),
checklist step 4. Next: watch for the head meeting the body at both, then
widen down travel and yaw one step at a time.

## Manual steering, 2026-09-17

For when the face is not in view yet, or the head should start somewhere
else. The app's joystick (top right of the toolbar) and the arrow keys send
`H,<sequence>,<x>,<y>` every 100 ms while held, each in [-1, 1]: +x turns to
the robot's right, +y tilts up. Release sends one centred line and stops.

- **Starts a session if none is running**, without Follow's confirmation
  (grabbing the stick is the intent), and over Wi-Fi with the passphrase.
- **Steering wins.** While H lines arrive, face targets are consumed and
  ignored, and the search does not run. Full deflection moves 4 raw per 80 ms
  tick, about 15 deg/s; deflection is squared for fine positioning near the
  centre, with a small dead zone. Always within the session's limits.
- **Deadman.** No H line for 300 ms: the head holds still, so a dropped link
  never keeps it moving.
- **Hands back.** 1.5 s after the last H line the tracker returns to idle and
  follows the next face from wherever the head was left.
- **Keeps the session alive.** An H line counts as activity for the lease and
  the idle ending, like an accepted target. `SBMV` reports `manual_inputs`; the
  trace shows mode 4, drawn green in `tools/follow_replay.py`.
- Allowed over Wi-Fi like `T,`: it only acts inside a session.

## The day following died silently, 2026-09-17

From the first sleep after each boot, head following did nothing and the light
bar stayed dark, for about two and a half hours, and nothing reported it.

- **Cause.** Sleep darkened the screen with `M5.Display.setBrightness`. At
  startup the sketch releases M5's I2C driver so the camera task owns the
  internal bus; that call made M5GFX take it back. Every later transaction to
  the base expander returned `ESP_ERR_INVALID_STATE` (259), so the motor power
  switch and the light bar were unreachable until reboot. Every flash reboots,
  so it looked fine after each one.
- **Why it was silent.** The firmware reported the failed power window with
  `Serial.println`, which a Wi-Fi viewer never sees. The app saw "authorized"
  and then nothing, called it `no_result`, which is retryable, and retried for
  hours. The session logs showed it plainly the whole time: no robot telemetry
  after 11:42.
- **Proof.** Read-only probe over USB: a clean base after a fresh boot,
  `error 259` after one sleep and wake; after the fix, clean after three.
- **Fix.** The backlight is the same two AXP2101 writes through the camera
  task's own driver (`backlight.h`), and so is power-off.
- **So it cannot recur quietly:** `companion/test_i2c_ownership.py` (source
  guard), `tools/check_sleep_wake.py` (hardware check), `SBHL` base health from
  the robot, `base_unreachable` over Wi-Fi, and `no_result_repeated` in the app.
  See "How to work here" in `next-session.md`.
- **The motors were left powered.** The bus died mid-session, so the cutoff
  could not be written, and the base keeps its latch across the head's reboots:
  motor power stayed on, torque on, for about two and a half hours, and every new
  session was correctly refused (`preflight_refused`) because power was already
  on. Cleared by hand with `probe_servos.py --disable-only`. The base health
  check now reads the latch whenever no session is running, turns it off if it
  finds it on, and reports `SBPW motor_power_left_on`.
- **A wrong turn worth remembering:** the USB port enumerating through the back
  connector for the first time that day looked like the cause (a shifted internal
  cable). It was a coincidence. The probe, not the theory, settled it.

## The wake scan, 2026-09-17 (built and flashed; not yet seen working)

When the owner wakes the robot, it looks around for someone before it settles.

- **App:** for 12 s after a wake, automatic following may start a session with
  nobody in view (`AutoFollow.shouldStart(..., wokeAt:)`); otherwise a session
  still needs a face. The usual gap between sessions does not hold it back.
- **Robot:** a session that begins within 20 s of `C,WAKE` starts with
  `HeadTracker::beginScan`: left limit, right limit, back to centre and up
  (level +90 raw), then down to the pitch minimum, then home. The eyes lead each
  turn, as they already do in a search. Every waypoint is inside the session's
  limits; it is quicker than a search (`scanStepRaw` 5, ~18 deg/s) and takes
  9.8 s in the native test at yaw +-96. While it runs the session is not counted
  as idle, so the 12 s "nobody here" clock starts when it finishes.
- **Two things that stopped it ever starting (2026-09-17),** both on the app
  side, both found from the session logs. Sleep ended the running session with
  the Stop button's code, which also switches automatic following off, so waking
  had nothing to start a session with. Then, fixed, the wake's one request was
  refused `follow_cooldown`: the robot will not start a session within 3 s of
  the last one ending, and sleeping has just ended one. The app treated its wake
  as spent. Now sleep ends the session and nothing more, and a cooldown refusal
  is asked again 1.5 s later while the 12 s wake window lasts.
- **Finding someone:** any accepted observation ends the scan at once and the
  face reacts: surprised 0.7 s, glee 0.9 s, then focused for as long as the
  session follows, then back to the chosen expression. The app's face does the
  same from `foundSomeoneAt`. An ordinary search finding a face is not a
  finding; only the wake scan is.
- **Not yet seen:** any of it on the robot. It moves the head through the whole
  allowed range on every wake, so the first run needs the owner at the robot.

## Calibration checklist, before `measured` may become true

Each step is one supervised session with a person at the robot, the cable in
the head port, and the stream on. Record the numbers in `head_tracker.h`.

1. **Yaw direction.** With `yawMin/yawMax` narrowed to centre +-48, hold a face
   left of frame and confirm the head turns robot-left. If it turns away,
   the image is mirrored relative to the assumption in `observe()` and the
   sign of `rawPerUnitX` must flip. Direction is done.

   **Centre** is not, and 460 is not a measurement: it is the BSP's
   `defaultZeroPos` for servo 1, taken on trust. On 2026-09-17 the owner saw
   the head sitting left of the feet at rest, and the wake scan reaching
   further left than right, which is what an assumed centre looks like. Measure
   it the way pitch level was measured, by eye: turn Follow on, steer with the
   direction pad or the arrow keys until the screen is square over the feet,
   let go and hold still, then
   `python3 tools/read_steered_yaw.py` reads the position out of the session
   log. It takes the last run of manual-mode samples and, within it, only the
   trailing ones that stopped moving, because the head resumes following 1.5 s
   after the last input and a reading taken mid-turn is a wrong answer that
   looks like a right one. Put the number in `kFollowYawCentre`; the limits are
   written around it, so they move with it.

   **Measured 2026-09-17: 431**, not 460. Two steered readings agreed (431 and
   432); a third at 471 came from a three-input nudge held 0.2 s and was
   discarded. Both symptoms fit: commanding 460 pointed the head 29 raw (9 deg)
   to the robot's right of square, and the wake scan reached 125 raw to the
   owner's left against 67 to their right. `kYawCenter` in the sketch stays at
   460 on purpose: the sweep's verified envelope is measured around that one.
2. **Pitch direction.** Same session, face high in frame, `pitchMax` at rest
   +32. Observe nod up or down; record `pitchUpSign`. If +raw nods *down*,
   the safe range is on the other side of rest and both pitch limits change.
   Direction is done (+raw is up). **Level** is not, and is what pitch
   following needs: `python3 companion/find_pitch_level.py <port>` bisects
   596..672 with `C,PITCHLEVEL,<raw>` (move pitch there and hold 4 s, one
   power window per boot, USB only), rebooting between steps and asking you
   up, down or level. A single request may not move more than 48 raw from
   where the head rests (`goal_too_far_from_start`, refused before torque),
   so a typo cannot swing the head. At most seven steps; it logs each answer to
   `calibration-pitch-level.jsonl` and prints the edit (set `pitchRest`,
   lower `pitchMin` if level is below 620, set `pitchRestConfirmed`). It never
   edits the header itself. Tests: `test_pitch_level.cpp` (parsing, and that
   Wi-Fi refuses it) and `test_find_pitch_level.py` (the bisection finds
   level within 4 raw for any level in range).
3. **Gains.** With directions right, check the head settles on a still face
   without oscillating. If it hunts, the deadbands are too narrow for this
   unit's standing error; if it lags, raise `rawPerUnitX/Y` a little.
4. **Widen.** Extend the limits toward what the sweep traversed (yaw +-288),
   remembering that the limits hang off the measured centre, not 460: at +-288
   around 431 the robot-left limit is 143, about 11 deg past the furthest the
   2026-09-15 sweep ever commanded (172, arrived 178). That side is new ground,
   so watch it and be ready to power the robot off by hand. M5Stack document
   the X axis as +-128 deg and the SCS0009 as 300 deg over 1024 steps, so the
   servo has room; the limits here are the body and the cable, not the motor.
   one session per step, watching for the head meeting the body. No source
   edit is needed: `STANBOT_FOLLOW_CALIBRATION=1 STANBOT_FOLLOW_YAW_RANGE=96
   firmware/build.sh`, then 144, 192, 240 and 288. Other values fail to
   compile, V reports `follow_yaw_range`, and `ota.py` checks it.
5. **Companion.** Done: the app sends `T,` targets with the frame's sequence
   number (sessions 2-5).

Only after 1-4 have been run on this unit and written down does `measured`
become true. Until then the command exists so that everything around it can
be reviewed, compiled and tested without anything being able to move.
