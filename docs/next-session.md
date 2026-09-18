# Next session

Handoff rewritten late on 2026-09-17, after a long day and a longer evening.
The day added voice phase 1, sleep and wake, a redesigned app, and found a fault
that had silently killed head following for hours. The evening measured the yaw
centre, widened travel to the full +-90 deg, rebuilt what the robot does when it
loses you, and taught it to say so when it cannot find you.

Read two things before touching anything: "The day following died silently" in
`docs/head-following.md`, and the screen entry at the top of `docs/recovery.md`
-- **if the display looks wrong, power cycle before diagnosing, because a
software reboot does not reset the panel.** Everything below is committed and
pushed.

## State right now

**On the robot:** firmware `380c983`, a calibration build made with
`STANBOT_FOLLOW_CALIBRATION=1 STANBOT_FOLLOW_PITCH=1 STANBOT_FOLLOW_YAW_RANGE=288`,
flashed over Wi-Fi and verified. `tools/check_sleep_wake.py` passes on it.
The app in `companion/StanbotCompanion/build/Stanbot.app` matches it.

Everything in this section is **on the robot and seen working** unless it says
otherwise.

- **Yaw** centre MEASURED 2026-09-17 at raw **431** (`kFollowYawCentre`), not
  the assumed 460: two steered readings agreed at 431 and 432. Travel widened
  to +-288 (+-90 deg), what the 2026-09-15 sweep traversed. Note +-288 around
  431 reaches 143 on the robot's left, ~11 deg past anything the sweep
  commanded: that side is new ground.
- **Pitch** level measured by eye at raw **614** (`calibration-pitch-level.jsonl`).
  Limits 594..870. Up verified: steered all the way up, the head met a hard stop
  at ~885 that the owner saw as vertical, so pitch is ~3.0 raw/deg and the
  maximum is 870. **Down does not exist on this axis** and is not a limit to
  widen: M5Stack document Y as 0..90 deg, level to straight up, and the
  2026-09-15 pitch motion puts 0 deg at raw ~620, so 594 is already below the
  manufacturer's zero. That is why 582 stalled at 592. The old note claiming the
  head looked "nearly straight down" there was a misreading and has been
  removed; level is the bottom of the range, and nothing about it needs
  re-checking.
- **Losing someone** is a two-stage hunt: a 32-raw glance each side of where
  they went, then, if that finds nobody, a whole-range look around -- and only
  then home. Seen working. 14.3 s end to end if nobody is ever found, so the
  session holds its idle clock while it runs.
- **A look around stops every 40 deg** rather than sweeping between the limits.
  It has to: on 2026-09-17 a whole sweep returned 114 frames with no face in any
  of them while the owner was in the room, because he was only ever in moving,
  blurred frames. Six stops across 180 deg, 400 ms each.
- **It checks the usual place first**: where the robot last saw someone, held
  1.2 s (`chairHoldMs`), then 20 deg either side, and only then the room. About
  1 s to be looking at someone in their chair; the 19 s room sweep happens only
  when they are not there. The owner's desk is the standing case: "I'll likely
  be at the same location... only if I'm not there should it sweep around the
  room."
- **The place survives a reset.** The robot reports it in `SBMV`
  (`last_seen_yaw/pitch`), the Mac keeps it (`RobotState`, UserDefaults) and
  hands it back on connecting with `K,lsy=..,lsp=..`; the robot answers `SBRS`
  with what it took. Seen surviving flashes. A cleverer memory -- clustering the
  last eight sightings -- was built and **deliberately reverted**: it lost in
  exactly the two cases it was for (the robot nudged round, the owner sitting
  elsewhere), where the single last place is wrong once and self-corrects. See
  "State that survives a reset" in `docs/head-following.md` before adding
  another carried value.
- **A reboot gets a look around too**, like a wake. The robot scans on its first
  session after a boot and says so in `V` as `scan_pending`; the app asks for
  that session on the robot's own answer rather than a stopwatch. Seen working:
  the trace swept 154..604 and found the owner at 8.4 s. **Do not gate this on a
  clock** -- two versions did, and both lapsed during the 60-90 s a flash and its
  checks take, so the robot came back and sat still.
- **"I couldn't find you"** with a sad face and a **Look again...** link when a
  look around finds nobody -- the robot's own `observations: 0`, not the app's
  guess. The link sends `C,LOOK` (authorized like `C,FOLLOW`). Built, NOT yet
  seen.
- **Eyes open before the head moves**, on the robot (a session waits for the
  boot screen to hand over and the lids to rise) and in the app (nothing starts
  during its 2.4 s waking).
- **Coming down is a sequence**, for a reboot, a firmware update and a sleep:
  the head comes home and level while it still has power, then the eyes close,
  then it restarts or darkens. `comeHome()` **latches** -- a face or a search
  must not divert it, and one that did left the head 50 deg off centre while
  reporting success. Bounded at 6 s, which the worst case (3.84 s) fits inside.
- **A reboot asked for mid-session** ends the session (`stopped_for_reboot`)
  rather than waiting out the 3-minute cap in silence, and `SBRB` goes through
  `Telemetry` so Wi-Fi hears it.
- **The light bar** separates looking from not finding: blue with a face, orange
  pulsing every 900 ms while the head hunts, dim steady purple when the camera
  is on and nobody has been found, dark otherwise. The owner saw the purple.
- **Following** is continuous: sessions repeat without reboots (3 s cooldown),
  each on a renewable power lease with a 3-minute hard maximum, and end after
  12 s with no face. Corrections use the head position when the frame was taken,
  60% gain, which stopped the hunting.
- **Manual steering:** `H,<seq>,<x>,<y>` from the app's direction pad or arrow
  keys; steering wins over faces and hands back to following 1.5 s after release.
- **Sleep and wake** (`C,SLEEP`, `C,WAKE`, no passphrase needed): the head comes
  home and level first (the app does NOT stop the session -- that would take away
  the power it parks with), the session ends `stopped_for_sleep`, the eyes close
  over 0.7 s, then the screen and backlight go dark, the light bar goes off and
  the stream stops; Wi-Fi stays up. Waking opens the eyes and ramps the light
  bar up over 0.6 s. `C,OFF` powers the robot down (passphrase over Wi-Fi); only
  its button brings it back. The backlight and power-off go through the camera
  task's own I2C driver (`backlight.h`), never M5Unified.
- **Wake scan:** a session starting within 20 s of a wake looks around before it
  settles, in the shape described above (usual place, beside it, then the room);
  a face ends it at once and the face reacts surprised, glee, focused. Seen
  working after a reboot; the reaction itself has not been watched closely.
- **Mouth:** opens and shapes with speech the Mac plays, from UDP port 3334,
  shown only while speaking. **Never yet seen on the robot.**
- **Trouble face** (X eyes, a frown) for 12 s after a session that ends in a
  fault. Never yet seen on the robot.
- **Health:** `SBHL` reports whether the head can reach its base, on connect and
  on change; motor power found on outside a session is turned off and reported.
- **Wi-Fi security:** only stream/display commands, `C,UNFOLLOW`, `C,SLEEP`,
  `C,WAKE` and `K,` (kept state: clamped on arrival, moves nothing by itself)
  are accepted over Wi-Fi unauthenticated; `C,FOLLOW`, `C,LOOK`, `C,REBOOT` and
  `C,OFF` need an HMAC challenge keyed by the OTA passphrase, which the app reads
  from `~/dotfiles/secrets.env` with sops.

**The Stanbot app** (`companion/StanbotCompanion/build/Stanbot.app`): see
`docs/app-design.md`. In short: the picture at the top of the window, mirrored;
the title bar has Stanbot's name and a red dot only when something is wrong
(and its eyes, while the panel is hidden); the toolbar has Sleep/Wake and the
panel toggle; the right panel is Stanbot's face (click it to sleep or wake) and
a gear with Head, Camera, Expression and Connection; Diagnostics is its own
window (Option-Command-D); Settings has tabs. Waking plays as a shot from behind
Stanbot's eyes (a Metal pass adds light through the lids and bokeh), at launch
too; asleep, z's drift up where the picture was.

**USB:** the cable is in the back port, and **since 11:47 on 2026-09-17 that
port enumerates** (`/dev/cu.usbmodem31201`), which it never did before
(`docs/transport.md`). So USB tools work without moving the cable. Nothing
explains the change; do not rely on it.

**Secrets:** `OPENAI_API_KEY_STANBOT` is in sops (a dedicated project key;
`gpt-live-1` and `gpt-realtime-2.1` both answer). A full 16 MB flash backup of
the robot is at `~/local-code/lottie-spike/FLASH-BACKUP-16MB.bin` (sha256
`ceb2f336...4c5848`, verified against the chip), taken with `ba9e961`-era
firmware plus the sleep work.

## Next, in order

1. **See what has never been seen**, with the owner at the robot: the mouth
   (Robot menu, Play Mouth Test; then set `robotLead` by eye), the trouble face,
   and the sad "I couldn't find you" face with its **Look again...** link.
   The mouth's *pipeline* is now proven without eyes -- `python3
   tools/check_mouth.py` sent 52 packets at the app's cadence and the robot
   accepted every one, 0 rejected (2026-09-17). So if the mouth does not appear,
   the fault is in the drawing or the app's envelope, not in the link.
2. **The sleep sequence the owner actually asked for.** Today's sleep parks the
   head home and level, ends the session, THEN closes the eyes and darkens --
   three beats. He wants one: lids closing as it sets off, the closed eyes
   visible all the way home, dark on arrival. **The naive way is known to be
   wrong**: drawing the face from inside `runFollowSession()` tore the panel and
   left the LCD's controller in a state that survived a reboot AND a reflash
   (only a battery power cycle cleared it; see `docs/recovery.md`). Doing it
   properly means the session yielding to `loop()` for rendering, not a second
   renderer inside the session.
3. **Watch the wider travel.** +-288 around 431 reaches 143 on the robot's left,
   about 11 deg past anything the 2026-09-15 sweep ever commanded. It has run
   many sessions there without complaint, but nothing has been inspected.
4. **Session telemetry arrives damaged occasionally.** Twice on 2026-09-17. One
   was the reboot racing its own report (fixed with a 700 ms drain); the other
   ended `session_idle` with no reboot involved, so something else drops lines
   over Wi-Fi now and then. The check reports it rather than handing over bad
   numbers, which is right, but the cause is unknown.
5. **Widen yaw beyond 288** only after a supervised sweep out there. M5Stack
   document the X axis as +-128 deg, so the servo has room past the +-90 deg
   built here; the compile-time assert caps at 288, and the cable and the body,
   not the motor, are the real limit.
6. **Voice.** Phase 3 is **done**: `companion/voice-spike` talked to
   `gpt-live-1` headlessly and settled everything `docs/voice.md` had guessed --
   four of those guesses were wrong, including the voice name and where it goes
   in the session object, and there is genuinely no interruption event, which
   makes the 200 ms playout buffer the mechanism rather than a nicety. $0.06 of
   a $5 cap. Phase 4's pure half is built and tested (`Live`, `PlayoutBuffer`,
   `VoiceSession`, `VoicePolicy`, `VoiceControl`; 23 tests, no network or sound
   card), and a disabled Talk control is in the toolbar saying what it waits
   for. **What is left all touches hardware:** the WebSocket transport,
   `AVAudioEngine` capture and playback with voice processing, wiring Talk,
   Settings and the inspector, the voice log, and the mouth from phase 1.
   **Phase 2 was not attempted** and needs the owner: it plays sound and makes
   judgements by ear (no echo into the capture, no ducking of a Meet call).
7. **When calibration is done**, decide whether `measured` can be true in the
   normal build rather than only in calibration builds.
8. **Gaze: paused.** See `docs/gaze.md`. The Studio Display (desk) camera code
   was removed 2026-09-17; `92ab70b` is the last commit with it.
9. **Worth doing:** the 5% CPU the panel's large face costs at rest
   (`docs/app-design.md`, "What it costs") is the app's biggest standing cost.

## How to work here

- **A change is finished when it is ON THE ROBOT, not when it is committed.**
  The owner said so on 2026-09-17 after answering "flash it" a dozen times: do
  not stop to ask. Commit (dirty builds report `dirty:true`), then
  `STANBOT_FOLLOW_CALIBRATION=1 STANBOT_FOLLOW_PITCH=1
  STANBOT_FOLLOW_YAW_RANGE=288 firmware/build.sh`, **and
  `companion/StanbotCompanion/build-app.sh` if any Swift changed** -- `swift
  build` and `swift test` do NOT produce the app, and shipping a stale bundle
  next to new firmware makes a working feature look broken. Quit Stanbot (it
  holds the robot's one Wi-Fi viewer slot), then from an agent shell on the mini
  run
  `ssh malpern@openclaw.local 'cd ~/local-code/stanbot && git pull -q; python3 firmware/ota.py'`.
  **Read the result before reporting it**: it must print `"verified": true`, and
  a flash can fail with "no V reply" when the robot has not released its viewer
  slot (wait a few seconds and retry). Reopen the app, then `tools/stanbot
  status` to confirm what actually landed. Still ask before anything that moves
  the head past its proven limits, or that needs the owner watching.
- **Agent shells on the mini cannot reach LAN hosts** (macOS Local Network
  privacy, no fix available). Route anything that talks to the robot over the
  network through `ssh malpern@openclaw.local`.
- **App:** `cd companion/StanbotCompanion && swift test && ./build-app.sh`,
  then `pkill -f Stanbot.app/Contents/MacOS/Stanbot; open build/Stanbot.app`.
- **If the screen looks wrong, POWER CYCLE before diagnosing** -- hold the
  robot's button; its battery means pulling USB is not enough. `esp_restart()`
  does not reset the LCD's own controller, so a panel corrupted by an aborted
  SPI transfer stays corrupted across a reboot and across a reflash. On
  2026-09-17 that made a software bug look like a failing ribbon cable, and made
  a correct revert look like it had not worked. See `docs/recovery.md`.
- **Do not draw the face from inside a session.** Every eye render belongs in
  `loop()`, which is blocked for the whole of `runFollowSession()` -- which is
  why the face freezes while the head moves. A second renderer inside the
  session tore the panel (above). If you add one anywhere, push the sprite ONLY
  when `eyes.update()` returns true: it paces itself at ~30 fps and returns
  false without touching the sprite, so pushing anyway shows a stale buffer.
- **Native firmware tests:** compile and run every `companion/test_*.cpp` with
  `c++ -std=c++17 -include initializer_list`. Python: `companion/test_*.py`.
- **What is it doing right now:** `python3 tools/stanbot status` (or `watch`).
  The app writes `~/Library/Logs/Stanbot/status.json` once a second: the
  connection, the firmware and its flags, the Follow toggle, the session state
  and the reason one cannot start, the camera, the face, and the remembered
  place. **Ask it before asking the owner.** It exists because on 2026-09-17
  two diagnoses turned into questions put to the owner about state the machine
  already knew. A stale file is reported as STALE and exits 2, because a
  plausible report from a dead app is worse than none.
- **Session logs:** `~/Library/Logs/Stanbot/follow-*.log` (APP lines per frame,
  SBPD trace, SBMV result, SBPW power). `tools/follow_replay.py` renders one;
  `tools/read_steered_yaw.py` reads the position the owner steered to out of
  the newest one, for calibrating by eye.
- **The camera task owns the internal I2C bus. Nothing in M5Unified may touch
  it after setup.** On 2026-09-17 sleep called `M5.Display.setBrightness`; M5's
  driver took the bus back and every transaction to the base failed from the
  first sleep until the next reboot: no motor power, no light bar, for hours,
  and each flash's reboot hid it. `companion/test_i2c_ownership.py` fails on any
  such call (mark a genuinely safe one `// i2c-ok: why`); use the camera task's
  driver instead, as `backlight.h` does. **After flashing anything that touches
  sleep, power, the display, the light bar or I2C, run
  `python3 tools/check_sleep_wake.py`** (robot on USB, Stanbot closed; moves
  nothing): it reads the base, sleeps and wakes three times, and reads it again.
  It stops the stream first, because text and frames share the USB channel and a
  reply arriving among JPEG data is shredded -- on 2026-09-17 that made it report
  a perfectly healthy robot as FAIL, which is the one thing this check must
  never do.
- **Failures must be loud.** The robot reports its base link as `SBHL` on every
  connect and whenever it changes; the app shows it as the orange alert, the red
  dot and the trouble face. A session refused for lack of motor power says so
  over Wi-Fi (`base_unreachable`, with the I2C error), not only to USB. Two
  sessions running with no result from the robot stop the automatic retrying
  (`no_result_repeated`). If you add a refusal path, send it through `Telemetry`,
  never `Serial` alone: over Wi-Fi, `Serial` is silence.
- **Safety:** stay supervised for anything that moves or widens limits. Never
  retry a refusal automatically. `DISABLE LATCH NOT VERIFIED` means power the
  robot off by hand (hold its button; it has a battery). Quit Stanbot before
  USB motion tools, or automatic following can start a session underneath them.

## The owner's preferences, learned this week

Calm over lively: the robot sits in front of them all day, so no fast eye
motion, no bright or flashing light, no bouncing (one blink on waking, not two).
Native Mac design, nothing floating over the video, and a spare one: the panel
is Stanbot's face and a gear, not a control board. Cinematic where it counts:
the waking shot is theirs, and they wanted it to feel like a first-person point
of view, not an effect. Plain safety signals. Wants things done and verified,
reported briefly, and wants failures loud: after the silent outage they asked
for both prevention and detection, not just the fix.

**Verify on the running thing.** Twice on 2026-09-17 still renders looked right
while the app did something else (an animation that never played; eyes drawn in
the wrong place). Photograph the running preview (`STANBOT_PREVIEW`,
`STANBOT_SNAPSHOT_DELAY`), and read the session logs after any firmware change
that could touch following: they showed the outage for hours before anyone
looked.
