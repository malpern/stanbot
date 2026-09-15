# Servo startup comparison — 2026-09-14

## Root cause of the standing error: I = 0 (measured 2026-09-15)

Both servos report P 15, D 15, I 0, punch 30, deadband 1/1 (EEPROM 21..27,
read-only). With no integral term the loop cannot correct a standing error, so
the servo stops where proportional drive no longer overcomes friction. Every
measurement on this robot fits: 3..4 raw steps short on 8-step moves, 4..6 on
90-degree legs, 2 on a 2-step recentre, always in the direction of travel, with
a flat plateau rather than slow creep. Gear backlash (spec <= 0.5 deg, ~1.7
steps) accounts for part of it.

This is the factory configuration, and the official firmware never reads present
position to check arrival — it snaps its own animation angle to the goal and
releases torque. So the shipped robot has the same error and does not notice.

Options, in increasing order of commitment, none taken yet:
1. Accept it. Treat within ~6 raw steps as arrived (what the sweep already
   does) and never re-issue goals to chase the remainder, which causes hunting.
2. Raise I a little (EEPROM 23) on the yaw servo only, and measure. This is a
   persistent write to the servo that survives reflashing and factory restore;
   it needs an explicit decision and a recorded before/after.
3. Leave gains alone and compensate in firmware with a bounded one-shot
   correction after settling. Keeps EEPROM pristine; adds control-loop
   complexity we would then own.

## One-second observation result

First two-leg session: start 476, goal 468, settled feedback 472 from 196ms to
1006ms. Return goal 476, feedback 473 from 304ms to 1006ms. Stable plateaus,
errors +4/-3, no improvement after 400ms on either leg. This weakens the short
observation-window hypothesis for this run. It does not prove servo accuracy,
backlash, load, or another cause. Return movement was only one net raw step
relative to the first plateau; physical observation remains necessary.
Output-disable latch verified after the session; no automatic repeat.
User subsequently confirmed visible rightward movement and return. Physical
bidirectional yaw is now observed; exact positioning is still unresolved.

Separate C,YAWRAMP / --yaw-ramp comparison uses eight linearly interpolated
waypoints per leg, scheduled about 40ms apart with official-style 20ms WritePos
timing. This is not the full official spring controller. Return interpolation
starts from actual last feedback, not the unreached first goal. Each waypoint
requires zero status/error and matching goal readback; every feedback sample
retains the same spatial guard. Seventeen position writes including initial
hold; both legs still observed for one second total, same four-second cutoff.
Native tests check interpolation monotonicity, envelope and exact final target
across the guarded start range. This test separates incremental delivery from
the previous single-goal timing without changing acceptance or EEPROM.

## Focused comparison and bounded session redesign

Reviewed official source checkout 1b5765599fba8aaad1811d9a79358ccc7051f5f3,
`firmware/main/hal/hal_servo.cpp`, `hal_io_expander.cpp`, and bundled BSP
`utils/motion/servo.cpp`. This source is not proven identical to the installed
factory binary. UART1/1Mbps/TX6/RX7, SCSCL encoding and VM output/pull-up agree.
Official position output uses WritePos(target, 20, 0), with the animation layer
updating at most 50Hz and snapping the final target. Ours uses one 300ms goal.
Official auto torque release checks rest; ours stopped observing after 400ms.
These differences warrant measurement, not a conclusion about defective hardware.
Do not import the complete HAL: its zero-position initialization can write NVS.

New explicit C,YAWSESSION / --yaw-session keeps startup, stable-position guards,
hold-before-torque and goal/status verification. Commands only start-8, then
the measured starting position (not saved home). Each leg is observed for 1000ms;
the second requires valid in-envelope feedback, five final samples spanning at
most two raw steps, moving=0, and at least two steps of rightward displacement.
Every sample must stay within start-11..start+3. Pitch remains torque-off.
No return after an error, unsettled feedback, absent displacement, or cutoff.
The dedicated independent cutoff is 4000ms, armed before VM enable; normal
monitoring ends by 3700ms. Existing single-nudge tests retain 2000ms cutoff.
No USB output until power-disable attempt, no automatic retries, no EEPROM/NVS
changes. Cutoff is a bounded software I2C attempt, not a guaranteed physical
supply measurement or a user-accessible emergency stop.

Session completion means measurement, not +/-2 target acceptance. Preserve
each leg's final error and trace. Compare feedback around 400ms with 1000ms:
late improvement supports insufficient settling time; unchanged shortfall
supports a plateau but does not identify its mechanical/electrical cause.
If inconclusive, next isolate the official 20ms incremental target pattern
within these same narrow bounds; do not grow travel or tune servo EEPROM.
Tilt and face-following remain disabled pending yaw assessment.

## Goal-readback result and opposite-direction comparison

Repeat stored target 481 exactly, write status/error 0/0; last feedback 477.
Moving flag went low at 169 ms while position still changed later, to 477 at
250 ms. No command encoding/readback mismatch established. User confirmed normal
small leftward movement without unusual behavior. M5Stack's ESPHome SCS9009
implementation uses the same big-endian SCS format; its WIP label and differing
angle mappings do not establish this robot's positioning accuracy or exact model.
No unsupported servo model assumption or tuning/EEPROM change made.

Prepared C,YAWBACK / --yaw-back for one fixed -8-step comparison toward center.
Same startup/stability/hold-goal/error/readback checks, speed, time, torque-off
cleanup and independent cutoff. Dynamic movement guard uses min(start,goal)-3
through max(start,goal)+3 for either sign. It is not auto-return and never runs
at boot; both directions share the same once-per-boot test gate. No arbitrary
host position or enlarged starting range is exposed.

## Deadband read result

Both servos returned raw CW/CCW deadband 1/1 during the next no-position-command
power window. Startup and disable latch checks passed again; no settings changed.
Do not attribute the observed 3–4-step final error to a configured large deadband
from this evidence. Position trace is still needed to distinguish continued
settling from a plateau; the first trace-bearing motion test has not yet run.

## First commanded yaw attempt

Four stable readings of 456 passed preflight; pitch was 640 with torque off.
Hold target 456 was written/verified before yaw torque enable; goal 464 followed.
Last feedback was 460, outside the +/-2 acceptance band, yielding
target_not_confirmed. Two position commands total; output disable verified,
total elapsed 1704 ms including post-cutoff checks. No automatic retry. This is
partial position-feedback change, not confirmed physical movement or a passed
motion test. User observation is required before further physical tests. Possible
timing/deadband/mechanical effects remain hypotheses; do not loosen acceptance
or increase travel merely to make it pass.

## Starting-position confirmation and stability gate

After the first yaw-test refusal at 434, user reported no movement and explicitly
confirmed the screen still centered over the feet and facing forward. Cause of
the difference from the earlier 456 remains unknown. Adjusted only the yaw lower
starting guard from 440 to 430 (upper 480 unchanged), covering both user-confirmed
center observations. Added four-read yaw stability requirement: total raw spread
at most 3, with three fresh samples 25 ms apart; all must remain within bounds
and the existing startup deadline. Missing/unstable samples refuse movement.
No calibration change; +8-step target, pitch torque-off, and cutoff unchanged.

## First yaw movement preparation

User confirmed no movement/buzzing on the successful readiness test. Prepared
explicit C,YAWTEST, separate from POWERTEST: narrow raw yaw 440..480 and pitch
610..650 starting guards around observed factory center; both torque off,
stationary, exact observed nonzero angle limits required. These guards are not
full travel calibration. Only yaw receives torque-on. Pitch remains torque-off
but shares the enabled supply. No mode/EEPROM/NVS writes.

Refresh yaw position, reject drift >3 raw steps, write/verify hold goal while
torque off, then enable yaw torque and request +8 raw steps (~2.5 degrees per
BSP mapping) over 300 ms. Monitor within start-3..goal+3, abort invalid/outlying
feedback, allow at most 400 ms with an overall 1850 ms observation deadline.
Independent 2000 ms cutoff remains armed throughout, plus broadcast torque-off
before normal cutoff. No automatic return move. Result distinguishes target
feedback from user-observed motion. The old motion-enabled full BSP is not used.

## Successful bounded fresh-enable test

On the next supervised startup, readiness polling established torque=0 at
845 ms for ID1 (10 attempts) and 870 ms for ID2 (1 attempt). Both returned valid
position/limits and moving=0. Enable/disable latch checks passed; enabled voltage
raw 51/52 became -1/-1 after cutoff. Zero position commands. This is direct
evidence that a single query near 200 ms was too early in this setup; use bounded
readiness checks, not a new assumed fixed delay. One successful startup is not
repeatability or motion validation. The earlier input-high predicate was also
invalid as a readiness requirement here. Input stayed zero throughout.

Next motion work must retain readiness and torque checks, independent cutoff,
and failure-to-disabled behavior. Read and preserve existing calibration/mode;
do not infer physical safe travel from EEPROM limits alone. No full-range sweep
or factory-default offset write is justified. User observation of this run is
pending before physical motion testing.

## Disable-only hardware result

After user-confirmed reset, one disable-only command succeeded. VM mode/latch/
input changed from 1/1/0 to 1/0/0, with no I2C read errors. Servo raw voltage
queries changed from 51/52 to -1/-1 after 250 ms. Disable latch verified;
physical rail-off deliberately remains unverified. Input bit was unchanged
despite the loss of servo replies. The evidence supports functional disable
control, not a calibrated supply measurement. No torque/position/calibration
writes or re-enable; power-enable tests remain blocked until reboot. Physical
twitch/buzz observation pending. Earlier preparation/install status is historical.

## Disable-only diagnostic prepared

Added explicit `C,POWEROFF` / host `--disable-only` mode. Requires stopped stream
and a readable output-mode/latch starting state. Samples servo voltage before
and 250 ms after one write clearing only VM's output bit; preserves other bits
and never writes direction, pulls, drive mode, torque, goals, or calibration.
The request blocks subsequent power-enable tests until reboot, including when
preflight fails. No automatic retry or re-enable. USB output follows the off
attempt. This is a diagnostic, not an emergency-stop interface: command handling
shares the camera task and may wait on capture.

Reports write ACK and output-latch-low verification separately; physical rail-off
remains explicitly unverified regardless of whether UART replies disappear.
CoreS3 build passed: 606,679 program bytes, 39,596 static RAM. Not flashed or run
on hardware; current robot firmware remains the earlier read-only extension.

## Datasheet follow-up

User confirmed side USB remained connected and no twitching/buzzing was noticed.
M5Stack's [M5IOE1 manual](https://github.com/m5stack/M5IOE1/blob/main/docs/IO_Expander_Datasheet_EN.pdf),
printed pages 5–6, documents continuous reads within 0x00..0x2f. Thus bulk-read
support is documented for M5IOE1; lack of auto-increment is no longer a leading
hypothesis. Exact correspondence with this device's revision 65 is not verified.
GPIO_I is described as real-time input; the manual does not state that output
mode forces input reads to zero. Open-drain is the documented default drive
mode. Do not change to push-pull without establishing the board's electrical
requirements; official VM startup uses pull-up without changing drive mode.

Prepared read-only Q telemetry for VM pull-up/down and drive-mode bits, plus
each servo's raw ReadVoltage result (units deliberately not inferred). No
power-control or motion changes. Build passed (605,667 program bytes, 39,588 RAM);
four host tests passed. Application-only flash at 0x10000 passed hash verification
on the known device; left in bootloader awaiting physical RST. New telemetry is
not yet hardware-tested. The next useful observation is this configuration/voltage snapshot,
not another powered test or a relaxed safety check.

## Subsequent hardware observation

Extended read-only Q after the next physical reset confirmed pull-up=1,
pull-down=0, open-drain=1 with mode/latch/input still 1/1/0. Both servos returned
voltage_raw=51, torque=0, moving=0; positions 457/628. These settings agree with
the official VM pull-up configuration and the documented default open-drain
mode. No conversion of voltage units is established. Changing drive mode is
not justified by this evidence. The next supervised diagnostic should test
disable-only behavior from this known responding state, without re-enabling
power, and distinguish output-latch confirmation from physical rail verification.
Loss of servo replies alone would not prove absence of voltage; independent
rail telemetry or measurement is needed for that stronger claim.

After installation and user-confirmed animated boot, one supervised power-test
request refused at preflight. A subsequent read-only snapshot showed mode=1,
latch=1, input=0, and valid replies from both servos (positions 454/628,
torque=0/0, moving=0/0, limits 20..1003 for both). The existing latch-high state
violates the probe's required off starting state. No new power window ran.
Retained base configuration across head reset is a hypothesis, not established
by a before/after measurement. Input-low cannot be used alone as evidence that
the servo supply is off. The earlier immediate-check timing hypothesis remains
untested; these findings do not justify bypassing the cutoff or enabling motion.

Code-only review; no flashing, motor commands, or calibration changes performed.

## Physical evidence

- User confirmed factory RGB Stripe red/green/blue responses with side USB connected.
- User tapped factory **Move To Home** and observed the head center relative to the feet.
- User subsequently tapped Done. No calibration-save operation was reported.
- This establishes factory-commanded motion under side USB, not calibrated travel,
  successful feedback from both axes, or reliable rear USB data.

## Sources

- Custom firmware: `firmware/camera_stream/camera_stream.ino` at repository commit
  `43c391c78420bdc6098451ce0af12392dcc22d9a`.
- Vendored BSP: `firmware/lib/StackChan-BSP/src/M5StackChan.cpp` and
  `src/drivers/PY32IOExpander/PY32IOExpander.cpp` under that library.
- Official source inspected: [motor-power startup](https://github.com/m5stack/StackChan/blob/1b5765599fba8aaad1811d9a79358ccc7051f5f3/firmware/main/hal/hal_io_expander.cpp)
  and [servo setup](https://github.com/m5stack/StackChan/blob/1b5765599fba8aaad1811d9a79358ccc7051f5f3/firmware/main/hal/hal_servo.cpp).
  This source revision has not been established as the exact source of the installed
  M5Burner V1.5.1 binary.

## Findings

1. UART1, 1 Mbps, TX6/RX7 and servo IDs 1/2 agree with official setup.
2. Official startup configures expander pin 0 as output with pull-up, enables
   motor power, and waits 200 ms. RGB initialization adds further delays.
   Our current probe also configures output/pull-up, but immediately requires
   mode, output latch, and input readback to all indicate high. Only after this
   succeeds does it spend 200 ms repeatedly sending torque-off.
3. Our latest recorded test cut power after about 6 ms because the combined
   high check failed. It never queried either servo. This is not evidence that
   the UART or servos failed to respond in that test.
4. The log omits individual register values and the read transaction status.
   It cannot distinguish stale input sampling, a latch/configuration mismatch,
   or an I2C read failure. Timing is a plausible cause, not a confirmed diagnosis.
5. The BSP reads GPIO registers individually; our probe reads contiguous blocks.
   Validate that assumption with single-register reads before relying on the
   bulk snapshot. The reviewed driver alone does not establish the expander's
   multi-register behavior.
6. An expander input/latch is not a measurement of the motor supply voltage.
   Likewise, official motion success does not establish trustworthy position
   feedback: the official wrapper can substitute commanded position when a
   position read fails.

## Prepared next diagnostic (built; not flashed or run on hardware)

Implemented single-register reads, separate `SBPD` immediate/settled/after-cutoff
snapshots with per-register I2C errors, and a 200 ms settling interval with
repeated torque-off attempts. Snapshots are printed only after the cutoff task
finishes. The independent cutoff, once-per-boot gate, stopped-stream requirement,
and refusal to send position/torque-on/calibration writes remain intact.

Build passed for CoreS3, PSRAM enabled, hardware CDC: 605,387 bytes program and
39,588 bytes static RAM. Four pseudo-terminal companion tests passed, including
low-immediate/high-settled diagnostic reporting and refusal when final enable or
cutoff verification fails. These host tests do not execute firmware or validate
physical cutoff timing. Factory V1.5.1 remains installed.

For the later supervised test, preserve the current factory recovery artifacts
and home calibration. Within the existing independent, bounded power cutoff,
allow the settling interval before deciding whether the input reflects enable.
Keep torque-off attempts during that interval, and refuse position commands entirely.
Require verified torque-off before reading position; never substitute a guessed
position for missing feedback. Power-off must run on every failure path.

Powering a servo is not a guarantee of no motion, even without a position command:
boot torque/default behavior must be treated as a physical-test risk. Obtain a
fresh stable-surface/clearance confirmation before that later hardware test.

Do not bypass the safety check, initialize the complete motion-enabled BSP, or
change saved offsets simply to make the test pass. Diagnose side-USB servo
startup separately from the still-unresolved rear-USB data path.
