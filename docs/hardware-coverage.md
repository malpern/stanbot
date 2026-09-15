# Hardware coverage

2026-09-15 servo gain registers read (read-only, EEPROM 21..25, both servos
identical): P 15, D 15, **I 0**, punch 30, deadband 1/1. I=0 means the position
loop has no integral term, so a standing error is never corrected: this is the
mechanical explanation for every shortfall measured on this robot (3..4 raw
steps on 8-step moves, 4..6 on 90-degree legs, 2 on a short recentre). It is
the factory setting and the official firmware never checks arrival, so this
robot is behaving as shipped. Changing it means an EEPROM write to the servo
that outlives any firmware; not done, and not proposed without a decision.

2026-09-15 yaw recentre after the sweep: goal 460, settled 458 (-2) in 1052 ms,
arrived and held. Start 458.

2026-09-15 FIRST PITCH MOTION under custom firmware, user-requested: ID 2 from
rest 620 to 636 (+16 raw = 5 degrees on the BSP mapping angle*16/50, i.e. the
official 5..85 degree range's lower bound) and back. Leg 1 settled 631 (-5),
leg 2 settled 621 (+1), both arrived, 1145 ms each; envelope 604..652; yaw
untouched at 458 torque-off throughout. Negative raw from rest is never
commanded: it would leave the official range. Physical direction (nod up vs
down), full travel and repeatability remain unverified.

2026-09-15 software reboot (`C,REBOOT` / `--reboot`) works and gives a fresh
once-per-boot power window with no physical RST. It only works while the
application is already running: after a flash the chip sits in the ROM loader,
and NEITHER esptool `--after hard-reset` NOR `--after watchdog-reset` starts the
application (both were tried; the port re-enumerates in the loader, so a present
port is not evidence the app is running). A physical RST is still required once
per flash.

2026-09-15 first full yaw sweep, user-requested and user-observed: center,
90 degrees robot-left (-288 raw), 90 degrees robot-right (+288 raw), center,
via `C,YAWSWEEP` / `--yaw-sweep` on head USB. Run 1 (build 613,691 bytes) moved
smoothly through all three legs with no grinding, stall, envelope trip or
reversal, servo tracking 8..24 raw steps behind an 8-step/40 ms goal ramp; but
an unsigned-time underflow ended each leg the moment its final waypoint was
sent, so there were no pauses and no settling. Fixed (613,719 bytes, app-only
flash at 0x10000 hash-verified, SHA-256 daf2a1db1d6ef6ffdb004d74536152725277f5fb2f346eaf0057d97ea5019ecf).
Run 2: 12,196 ms, 152 position writes, every leg arrived and held: center
454 (-6), left 178 (+6), right 744 (-4), center 460 (0); pitch 621 torque-off
throughout; enable and disable latches verified. Start position was 407 after
the previous torque-off, and the first leg recentred it. Steady-state error
is 4..6 raw steps (about 1.5 degrees) in the direction of travel on long
moves, consistent with SCS0009 P-only control and the earlier 3..4-step
shortfall on 8-step moves. Observed bidirectional 180-degree yaw is now
established on head USB; base USB still does not enumerate.

2026-09-14 incremental-target comparison installed, not exercised: YAWRAMP
eight waypoints per leg, official-style 20ms goal timing, ~40ms scheduled
updates; same session cutoff and envelope. Build 610,499 program bytes /
39,580 static RAM; 22 host tests and native settling/interpolation assertions
passed. App-only flash 610,640 bytes at 0x10000 hash-verified on known device.
Left in bootloader for physical RST/readiness; no ramp movement yet. No saved
home or calibration writes. Next single supervised command: --yaw-ramp.

2026-09-14 user confirmed the two-leg session visibly moved right and returned.
This establishes observed bidirectional yaw under custom firmware on side USB;
feedback still ended three steps below its starting value, so exact return and
full calibration are not claimed. Preparing separate YAWRAMP comparison, same
spatial envelope and cutoff, changing only goal delivery to gradual waypoints.

2026-09-14 first bounded yaw session executed after user readiness. Stable start
476 (four identical readings), pitch 639 torque-off. First goal 468: feedback
472 from 196ms through 1006ms, error +4. Conditional return goal 476: feedback
471 at 142..250ms, 473 from 304ms through 1006ms, error -3. Both legs 38 samples,
final five-sample spread zero; session_measured means measurements completed,
NOT targets reached or return-to-start confirmed. Final goal readback 476,
write status/error 0/0. Startup readiness 848/879ms; three position writes
(hold, rightward goal, return). Disable latch verified, post-cutoff voltage
queries -1/-1; elapsed including cleanup 3377ms. Physical observation pending.
No further movement issued. In this run, extending observation to one second
did not improve either plateau after 400ms. Simple insufficient observation
time is not supported for these moves; root cause remains unknown. Next useful
comparison is the official incremental-target pattern within the same narrow
spatial envelope, not more identical tests or wider travel.

2026-09-14 bounded two-leg yaw session prepared after stepping back from repeated
nudges. Official comparison documented in servo-startup-review.md: official
20ms incremental goals differ from our single 300ms goal / 400ms observation.
Cause of shortfall remains unproven. New explicit --yaw-session observes a
start-8 goal for one second, then conditionally returns to measured start for
one second; independent 4s cutoff, unchanged narrow spatial guard, pitch off,
no calibration writes. Invalid/unsettled/no-rightward-displacement feedback
prevents return. Session completion is NOT exact target acceptance.
Build: 610,015 program bytes / 39,580 static RAM. 21 host tests passed, two
targeted session tests rechecked after final guard change; native C++ settling
gate boundary assertions passed. These are not hardware validation. App-only
610,160-byte flash at 0x10000 hash-verified on MAC 68:ee:8f:d8:4f:04. Left in
bootloader, pending user reset/readiness. No session or motion issued this turn.

2026-09-14 opposite-direction diagnostic installed: fixed -8-step YAWBACK,
sharing the forward test's once-per-boot gate and unchanged cutoff, speed,
stability and status checks. Build 609,003 program bytes / 39,596 static RAM;
18 host protocol tests passed, including wrong-direction rejection. Independent
verify-flash matched all 609,152 application bytes at 0x10000 on the known
device (MAC 68:ee:8f:d8:4f:04). Left in bootloader awaiting brief physical RST
and observation of one small rightward move. No reverse movement tested yet;
no calibration or EEPROM changes.

2026-09-14 goal-readback yaw repeat: four stable samples 473; requested/stored
goal 481, write status/error both 0. Trace 473 at 7..88 ms, 474 at 115..196 ms,
476 at 223 ms, 477 at 250..385 ms. Moving flag became 0 at 169 ms before later
position changes; it alone does not establish settling. Target_not_confirmed,
two position commands, disable latch verified, post-cutoff voltage replies
absent, elapsed 1716 ms. Startup 847/878 ms. No command/readback mismatch found.
Further same-direction repetitions paused near the narrow starting guard's
upper bound; do not widen it or increase travel automatically. User confirmed
a normal small leftward move without grinding or unusual behavior. Actuator
accuracy/settling cause remains unresolved.

2026-09-14 goal-readback/status revision installed for user-requested repeat:
hold/torque/goal operations now require zero servo status; goal register readback
must match before monitoring. Position/moving status errors abort. Range/speed/
cutoff unchanged. Build 608,899 program bytes / 39,596 RAM; sixteen host tests
passed. Application 609,040 bytes hash-verified at 0x10000; waiting for physical
RST. No new motion command issued yet.

2026-09-14 traced yaw attempt: stable yaw samples 468..469 (4 samples), start
469, target 477. Trace: 469 at 7..142 ms with moving=1, 471 at 169 ms,
472 at 196..385 ms with moving=0. Target_not_confirmed; two position commands.
Readiness 849/880 ms; initial pitch 639; both deadbands 1/1. Disable latch
verified, voltage replies absent after cutoff, elapsed 1714 ms. No timeout
extension or tolerance increase. User requested one repeat rather than providing
physical observation of this run. Preparing goal-register readback and status
byte checks: the driver ACK returns success even with a nonzero servo status.
This is an identified diagnostic gap, not proof an error occurred in prior runs.

2026-09-14 deadband POWERTEST passed: both servos CW_DEAD=1/CCW_DEAD=1 (raw,
unchanged). Readiness 846 ms / 10 attempts (yaw), 877 ms / 1 attempt (pitch).
Positions 464/639, torque=0, moving=0, limits 20..1003, enabled voltage raw 51/51;
post-cutoff voltage -1/-1. Enable/disable latch checks passed, elapsed 1198 ms,
zero position commands. These settings alone do not establish why previous yaw
moves missed target by 3–4 steps. No acceptance or EEPROM change. Next proposed
test is unchanged +8-step yaw with installed time-series telemetry, requiring
physical RST because the once-per-boot window was used.

2026-09-14 deadband/trace diagnostic installed: build 608,551 program bytes,
39,596 static RAM. Sixteen host tests plus two trace-output targeted tests passed.
Application-only 608,704-byte flash hash-verified. Left in bootloader awaiting
brief physical RST; next planned test is POWERTEST (no position writes), to read
deadband settings. No deadband setting is changed. Trace only collects in the
separate explicit yaw test; no further motion test has been run.

2026-09-14 user confirmed repeat movement was left as viewed facing the screen,
with movement sound but no grinding. This establishes observed yaw direction
for positive raw increments; not general acoustic/mechanical health. Preparing
read-only CW/CCW deadband register telemetry and bounded position/moving trace
to distinguish settling from a deadband hypothesis. No tolerance, speed, or
travel increase; output buffered until after cutoff. No new test run yet.

2026-09-14 user confirmed visible head movement during the unchanged repeat yaw
test. Custom yaw actuation is now physically observed on side USB. This is a
partial result: target tolerance still failed, and physical direction/buzzing,
travel calibration, tilt motion, and sustained following remain unverified.
No additional command sent following that confirmation; motor enable remains low.

2026-09-14 user-requested single repeat of unchanged yaw test after physical RST:
four stable readings 460, goal 468, final feedback 465. Target_not_confirmed
(three steps short, outside +/-2 acceptance), two position commands; readiness
845/870 ms, initial pitch 640, both torque-off/moving=0. Enable/disable latch
checks passed, post-cutoff voltage queries -1/-1, total elapsed 1699 ms.
No further repeat or adjustment. User had tentatively observed prior movement;
visible direction and sound for this repeat remain pending. Motor enable low.

2026-09-14 stability-checked supervised yaw attempt: ID1 ready 849 ms / 10
attempts, ID2 ready 874 ms / 1 attempt; initial positions 456/640, torque=0,
moving=0, limits 20..1003, voltage raw 51/52. Four yaw samples all 456.
Two position commands sent (hold 456, goal 464); result target_not_confirmed,
last position 460. Enable/disable latch verification passed; post-cutoff voltage
queries -1/-1; total elapsed 1704 ms. First custom commanded-motion attempt,
but target not reached within acceptance threshold/time. Actual visible motion,
direction, sound pending user observation. No repeat or range expansion. Motor
enable left low; full motion/following remains locked.

2026-09-14 user confirmed visually centered/forward with no observed movement
despite raw yaw 434. Lower starting guard adjusted 440->430, upper 480 unchanged;
added four-read stability gate (spread <=3 raw steps, bounded time). Sixteen host
tests passed. CoreS3 build 608,155 program bytes / 39,596 static RAM; application
608,304 bytes flashed at 0x10000 and hash-verified. No NVS/partition/calibration
writes. Left in bootloader for physical RST; updated yaw test not yet run.

2026-09-14 first supervised YAWTEST refused before movement: readiness succeeded
at 834 ms (ID1, 10 attempts) / 859 ms (ID2, 1 attempt). Positions 434/628,
torque 0/0, moving 0/0, limits 20..1003, voltage raw 51/52. Yaw 434 lies outside
the approved starting guard 440..480; result preflight_refused, zero position
commands. Enable/disable latch checks passed, after-cutoff voltage queries -1/-1,
elapsed 1174 ms. Prior yaw reading was 456; cause of position difference is
unknown. No automatic retry, guard widening, calibration rewrite or movement.
Physical position/possible cable or handling shift needs user confirmation.

2026-09-14 yaw-only test prepared and installed: user confirmed successful
readiness test had no movement/buzz. Separate explicit YAWTEST permits +8 raw
yaw steps only near observed center, retains pitch torque-off, independent
cutoff, fresh-position/torque/limits checks, and no calibration writes. Twelve
host tests passed; firmware built 607,963 program bytes / 39,596 static RAM.
Application-only 608,112-byte write hash-verified on known device. Left in
bootloader awaiting physical RST and user readiness for first motion test.
No custom motion command has yet been run on hardware. See servo-startup-review.

2026-09-14 bounded readiness hardware test PASSED for this one startup: servo 1
confirmed torque off after 10 attempts at 845 ms; servo 2 on first attempt at
870 ms. Positions 456/630, torque 0/0, moving 0/0, limits 20..1003 for both.
Raw enabled voltage 51/52; both post-cutoff queries returned -1. Enable latch
high and disable latch low verified; input remained zero in all snapshots.
Total diagnostic elapsed 1,184 ms (includes post-cutoff delay/reads), zero
position commands. Physical supply-off remains unmeasured. This supports startup
readiness latency as the reason the single ~200 ms query failed; it does not
prove a universal boot delay or repeated-cycle reliability. Physical twitch/buzz
observation pending. Motor enable left low; no further test auto-repeated.

2026-09-14 bounded startup-readiness revision installed: user observed no twitch/
buzz in preceding failed window. Official Hal::init performs RGB delays, RTC and
IMU initialization before servo_init. New diagnostic retries missing torque
replies within one 1,200 ms startup budget measured from enable, retaining the
independent 2,000 ms cutoff and once-per-boot limit. Explicit nonzero torque
aborts. Reports attempts and first torque-off reply time; no movement commands.
Eight host tests passed; firmware compiled (607,043 program bytes, 39,596 static
RAM). Application-only flash 607,184 bytes hash-verified on known device. Awaiting
brief physical RST; hardware startup-readiness outcome not yet established.

2026-09-14 revised supervised power window: immediate/settled VM mode/latch/input
1/1/0, after cutoff 1/0/0; all I2C reads succeeded. Enable-write ACK, enable-latch
high and disable-latch low verified. First servo torque read returned -1; probe
aborted further enabled queries as designed. Thus ID1 position/voltage and ID2
enabled fields are unqueried sentinel -1, not independent failed reads. Both
post-cutoff voltage reads returned -1. Total elapsed 545 ms includes 250 ms
post-cutoff settling and later reads; not energized duration. No position goals
sent, no retry; motion remains locked. Physical observation pending. Unlike
the retained factory-enabled state, this brief fresh-enable sequence did not
establish servo feedback; startup timing/supply behavior remains unresolved.

2026-09-14 revised bounded enable diagnostic: user reported no twitch/buzz in
disable-only test. Replaced GPIO-input predicates with explicit output-mode/
latch predicates based on that test; input remains reported, not a rail sensor.
Reports `enable_latch_high_verified`, `disable_latch_low_verified`, and always
`rail_off_verified:false`. Keeps independent cutoff, once-per-boot power window,
200 ms torque-off settling, and torque=0 requirement before accepting feedback.
Adds raw servo voltage during the window and 250 ms after cutoff; elapsed_ms
includes post-cutoff observations, not just energized time. Eight host tests
passed; CoreS3 build 606,851 program bytes, 39,596 static RAM. Application-only
606,992-byte flash at 0x10000 verified on known device. Awaiting physical RST;
no re-enable or movement test has run with this revision.

2026-09-14 supervised disable-only test completed: before mode/latch/input=1/1/0;
after=1/0/0, all three register reads successful. Off write ACK and output-latch
low verified. Servo voltage raw values before were 51 (ID1), 52 (ID2); both
returned -1 after the 250 ms wait. This is consistent with motor-supply disable,
but is not an independent voltage measurement. Input stayed zero across both
states, so it cannot distinguish supply on/off in this observation. No position
or torque writes; no re-enable requested, and enable tests blocked until reboot.
User physical observation pending. Leave disable latched; motion remains locked.

2026-09-14 disable-only diagnostic installed with user present: application-only
606,832-byte write at 0x10000 to the known ESP32-S3 passed hash verification.
No full erase or NVS/calibration write. Left in bootloader pending physical RST;
disable-only test has not yet run. Seven host tests passed before installation.

2026-09-14 disable-only diagnostic prepared, not flashed: explicit POWEROFF
clears only the motor-enable output and blocks later enable tests until reboot.
No torque or position writes. Samples raw voltage before/after; never claims
physical supply-off from a latch or missing replies. Build passed (606,679
program bytes, 39,596 static RAM). Hardware verification pending.

2026-09-14 read-only extended Q after user reset: base version 65, VM output
mode=1, latch=1, input=0, pull-up=1, pull-down=0, open-drain=1. Servo 1 position
457; servo 2 position 628. Both returned torque=0, moving=0, limits 20..1003,
voltage_raw=51. Host probe passed. Raw voltage units are not yet verified for
the installed servo model; no conversion to volts is claimed. No power writes,
movement goals, or calibration changes were sent. VM input remains inconsistent
with treating it as a motor-supply indicator. Cutoff effectiveness is unverified
in this retained-state scenario; motion remains locked.

2026-09-14 read-only telemetry extension: CoreS3 build passed (605,667 program
bytes, 39,588 static RAM), four host tests passed. Application-only write at
0x10000 hash-verified; no partition/NVS rewrite. Adds VM pulls/drive mode and raw
servo voltage to Q; no motor-control change. Awaiting brief physical RST and
new readings. User confirmed no twitching/buzzing during the preceding attempt.

2026-09-14 supervised settling-test attempt: user confirmed animated eyes after
brief RST. The single `C,POWERTEST` request returned
`preflight_failed_no_power_enabled`; no enable window ran and no automatic retry
was made. Subsequent read-only `Q` succeeded: base version 65, output mode=1,
output latch=1, input level=0. Servo 1: position 454, torque 0, limits 20..1003,
moving 0. Servo 2: position 628, torque 0, limits 20..1003, moving 0.
Both servos now provide valid feedback under custom firmware on side USB.
The high output latch explains refusal of an off-only preflight; retained
factory base state is plausible but not proven. A low expander input did not
prevent successful UART replies and must not be treated as proof of no motor
supply. No position/calibration command was sent. Physical observation of the
attempt remains pending; smooth movement and safe travel remain unverified.

2026-09-14 settling diagnostic installation: full current factory backup read and
digest-verified; custom diagnostic flashed with all segment hashes verified.
Left in bootloader awaiting physical RST. This supersedes the preparation note's
installed-firmware status below; boot and powered servo testing remain pending.

2026-09-14 diagnostic preparation (not flashed): motor-enable sampling now uses
single-register reads with immediate/200 ms settled/after-cutoff snapshots and
per-register I2C errors. Automatic cutoff and no-position-command restrictions
remain. CoreS3 build passed (605,387 bytes program, 39,588 bytes static RAM);
four host pseudo-terminal tests passed. No new physical validation occurred.
Factory V1.5.1 remains installed. See `servo-startup-review.md`.

Requested coverage; exact components and supported functions must be confirmed against official board documentation. Results below distinguish implementation, build/transport validation, and physical validation.

## Build and transport record

2026-09-14 diagnostic results: user photos of CoreS3 UserDemo show USB input
5.2 V via head USB and 5.0 V via rear USB, with USB IN/BUS OUT unchanged.
Rear USB power therefore reaches the head at this observation; sustained
charging and motor supply remain unverified. Battery display changed from
0.0 V to 4.2 V; demo charge-state gating prevents treating the first value as
proof of a dead battery. Rear USB remained absent after user-confirmed ROM
download entry; switching to side restored known device enumeration. A second
cable, reported directly connected to Mini, also failed at rear and worked
at side. Strong evidence of rear/internal data-path fault, exact part unknown.

Returned to StackChan-UserDemo V1.5.1 with full erase and hash-verified write,
left in bootloader pending user startup and RGB-only factory test. No servo
test commanded. See [recovery](recovery.md).

2026-09-14 update: user confirmed official StackChan firmware startup. Rear
USB still absent under official firmware; side USB restored known device.
Gentle central black cable press after shutdown did not restore rear data,
including after restart. Installed official CoreS3 UserDemo v0.12 via side USB,
full erase and 7,138,816-byte write hash verified. Left in bootloader pending
user startup and side/rear Power Test readings. No charging result established.

2026-09-14 factory comparison: rear USB absent in both plug orientations;
same cable restored known device enumeration through head USB. Rear red LED
follows cable insertion; eyes persist unplugged, so neither charging nor rear
power delivery to the head is established. With user authorization and physical
clearance confirmed, saved a private full 16 MB backup and verified its digest
against device flash. Installed M5Stack StackChan-UserDemo V1.5.1 from the
downloaded M5Burner catalogue with full erase and written-data hash verification.
Left in bootloader awaiting physical startup. Factory operation, rear USB under
factory firmware, charging, and motion remain unverified. See [recovery](recovery.md).

2026-09-14 pull-up correction: matched BSP VM pin pull-up/no-pull-down setup,
verified output configuration while low, and required output-mode/latch/input
readback high before servo queries. Four host simulation tests passed; firmware
built (604,827 program bytes, 39,588 static RAM bytes) and upload hash verified.
One authorized live test returned write-ACK=true, enable-high-verified=false,
power-off-verified=true, elapsed=6 ms, position-commands=0. Neither servo was
queried in this run because enable verification failed. Individual on-state
register values were not logged, so this does not identify which check failed
or establish motor-rail voltage. The immediate readback timing and base pin
behavior need investigation before repeating powered tests. Motion remains locked.

2026-09-14 supervised power preflight: added one power window per boot, accepted
only with streaming stopped. Independent core-1 cutoff task requests VM low by
two seconds, with up to three 100 ms I2C write attempts. No goal, torque-on,
mode, or EEPROM writes. Three host pseudo-terminal tests passed (valid feedback,
invalid position rejection, unverified cutoff error); these do not validate
physical cutoff under hardware/bus failure. Firmware built at 604,571 program
bytes and 39,588 static RAM bytes; flashed with hash verification.

One authorized live test returned power-write ACK=true, power-off-verified=true,
elapsed=244 ms, position-commands=0. Servo 1 torque query returned -1, so no
position was accepted and servo 2 was not queried (its report remains -1).
The low output latch/input were verified after cutoff. Motor-rail voltage and
the enable signal during the on-window were not measured, so ACK does not prove
that the servos actually received power. Calibration remains blocked on feedback.

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
| Head pan servo | Calibrate safe range and direction; verify smooth bounded motion and stop behavior. | Plan-driven bounded motion (`C,YAWSWEEP`, `C,CENTER`) with envelope guard, stall abort and independent power cutoff | Partial — 2026-09-15. A full 180 degree sweep (centre, 90 each way, centre) ran smoothly and was observed physically; every leg arrived and held within 6 raw steps. Travel limits are still guards, not a measured calibration, and sustained following is untested. |
| Head tilt servo | Calibrate safe range and direction; verify smooth bounded motion and stop behavior. | `C,PITCHNUDGE`: +16 raw (5 degrees) from rest and back; negative raw from rest is never commanded | Partial — 2026-09-15. First pitch motion ran, both legs arrived (errors -5 and +1). Only 5 degrees of the official 5-85 range exercised; direction, full travel and repeatability unverified. |
| Display | Verify avatar rendering, blinking, and attention states at startup. | AGPL-3.0-or-later M5GFX port companion based on `esp32-eyes`; compiled and flashed. | Base animated renderer: Yes — 2026-09-13. CoreS3-profile rebuild and emotion variants: awaiting fresh visual confirmation; attention state remains untested. |
| Display touch | Verify coordinates and press/release events across the display. | No | No |
| Camera | Capture frames and verify face presence/loss under varied lighting. | Motion-free `camera_stream` sends bounded QVGA JPEG at quality 90 over USB; the Mac app renders it and overlays macOS Vision face rectangles. | Frame transport, live display and face lock-on: Yes - 2026-09-15, holds a selected face. Varied lighting, target-loss behaviour and sustained performance: No. |
| Dual microphones | Verify both channels with known audio and distinguish channel input. | No | No |
| Speaker | Play a known signal at a conservative level and inspect distortion. | No | No |
| Wi-Fi | Verify local connection, reconnect behavior, and operation without internet. | No | No |
| Bluetooth | Verify discovery and an appropriate supported local data exchange. | No | No |
| RGB LEDs | Exercise each LED and channel at bounded brightness. | No custom implementation | Factory RGB Stripe red/green/blue changes confirmed by user on side USB, 2026-09-14; individual LEDs and custom control unverified. |
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
