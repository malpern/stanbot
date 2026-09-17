# Next session

Handoff rewritten at the end of 2026-09-17, a long day that added voice phase 1,
sleep and wake, a redesigned app, and found and fixed a fault that had silently
killed head following for hours (read "The day following died silently" in
`docs/head-following.md` first: its lessons shape how to work here). Everything
below is committed and pushed.

## State right now

**On the robot:** firmware `f907097`, a calibration build made with
`STANBOT_FOLLOW_CALIBRATION=1 STANBOT_FOLLOW_PITCH=1 STANBOT_FOLLOW_YAW_RANGE=96`,
flashed over Wi-Fi and verified; a centre-431, yaw +-288 build is ready but
unflashed. `tools/check_sleep_wake.py` passes on it, and a
full follow session ran on it at 14:31 (301 observations, ended `session_idle`).

- **Yaw** centre MEASURED 2026-09-17 at raw **431** (`kFollowYawCentre`), not
  the assumed 460: two steered readings agreed at 431 and 432. Travel widened
  to +-288 (+-90 deg), what the 2026-09-15 sweep traversed. Note +-288 around
  431 reaches 143 on the robot's left, ~11 deg past anything the sweep
  commanded: that side is new ground.
- **Pitch** level measured by eye at raw **614** (`calibration-pitch-level.jsonl`).
  Limits 594..870. Up verified: steered all the way up, the head met a hard stop
  at ~885 that the owner saw as vertical (`stall_detected`, power off verified),
  so pitch is ~3.0 raw/deg and the maximum is 870. Down: 582 was tried; the head
  stopped at 592, pressing, and looked nearly straight down to the owner, so the
  minimum is the unpowered rest, 594. That look does not fit ~3 raw/deg from a
  level of 614: **re-check level before changing pitch again.** A head left
  resting above 870 is refused until lowered by hand.
- **Losing someone** is a two-stage hunt (2026-09-17, at the owner's request):
  a 32-raw glance each side of where they went, then, if that finds nobody, the
  wake scan's whole-range look -- out to one yaw limit, out to the other, up,
  down -- and only then back to rest. At yaw 143..719 the whole thing is 14.3 s,
  so the session holds its idle clock while it runs. Built, NOT yet seen.
- **Nothing searches until something is lost.** The app starts a session only
  on a confirmed face or within 12 s of a wake, so a just-rebooted robot with
  nobody in view sits still indefinitely. Asked about 2026-09-17 after a flash.
- **The light bar** now separates looking from not finding: blue with a face,
  orange pulsing every 900 ms while the head hunts, dim purple when the camera
  is on and nobody has been found, dark otherwise. Built, NOT yet seen.
- **Following** is continuous: sessions repeat without reboots (3 s cooldown),
  each on a renewable power lease with a 3-minute hard maximum, and end after
  12 s with no face. Corrections use the head position when the frame was taken,
  60% gain, which stopped the hunting.
- **Manual steering:** `H,<seq>,<x>,<y>` from the app's direction pad or arrow
  keys; steering wins over faces and hands back to following 1.5 s after release.
- **Sleep and wake** (`C,SLEEP`, `C,WAKE`, no passphrase needed): the eyes close
  over 0.7 s, then the screen and backlight go dark, the light bar goes off and
  the stream stops; Wi-Fi stays up. Waking opens the eyes and ramps the light
  bar up over 0.6 s. `C,OFF` powers the robot down (passphrase over Wi-Fi); only
  its button brings it back. The backlight and power-off go through the camera
  task's own I2C driver (`backlight.h`), never M5Unified.
- **Wake scan:** a session starting within 20 s of a wake first looks around
  (left, right, up, down, home, ~10 s); a face ends it and the face reacts
  surprised, glee, focused. **Built and flashed; never yet seen working**, because
  until 14:30 no session could power the head.
- **Mouth:** opens and shapes with speech the Mac plays, from UDP port 3334,
  shown only while speaking. **Never yet seen on the robot.**
- **Trouble face** (X eyes, a frown) for 12 s after a session that ends in a
  fault. Never yet seen on the robot.
- **Light bar:** blue with a face, a gentle orange breath while the camera
  streams with none, dark otherwise and while asleep. Confirmed by the owner,
  including coming back after a sleep and wake (2026-09-17, after the I2C fix).
- **Health:** `SBHL` reports whether the head can reach its base, on connect and
  on change; motor power found on outside a session is turned off and reported.
- **Wi-Fi security:** only stream/display commands, `C,UNFOLLOW`, `C,SLEEP` and
  `C,WAKE` are accepted over Wi-Fi unauthenticated; `C,FOLLOW`, `C,REBOOT` and
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

1. **Confirm the new centre and the wider travel on the robot.** Measured and
   built but NOT yet flashed as of this writing: centre 431 and yaw +-288. At
   rest the head should now sit square over the feet, and the wake scan should
   reach equally to either side. Watch the first excursion to the robot's left:
   143 raw is past anything the sweep commanded.
2. **See what has never been seen**, with the owner at the robot: the wake scan
   (sleep, then wake while out of view), the mouth
   (Robot menu, Play Mouth Test; then set `robotLead` by eye), the sleep
   animation on the robot's screen, and the trouble face.
3. **Re-check pitch level** (steer until the face looks straight ahead, read
   pitch from the follow log), then decide the down limit.
4. **Widen yaw beyond 288** only after a supervised sweep out there. M5Stack
   document the X axis as +-128 deg, so the servo has room past the +-90 deg
   built here; the compile-time assert caps at 288, and the cable and the body,
   not the motor, are the real limit.
5. **Voice, phase 2 and 3** (`docs/voice.md`): echo and Meet-call tests on the
   Mac, then a command-line `gpt-live-1` client. The Talk button is phase 4.
6. **When calibration is done**, decide whether `measured` can be true in the
   normal build rather than only in calibration builds.
7. **Gaze: paused.** See `docs/gaze.md`. The Studio Display (desk) camera code
   was removed 2026-09-17; `92ab70b` is the last commit with it.
8. **Worth doing:** the 5% CPU the panel's large face costs at rest
   (`docs/app-design.md`, "What it costs") is the app's biggest standing cost.

## How to work here

- **Build and flash firmware:** commit first (dirty builds report `dirty:true`),
  then `STANBOT_FOLLOW_CALIBRATION=1 STANBOT_FOLLOW_PITCH=1
  STANBOT_FOLLOW_YAW_RANGE=96 firmware/build.sh`. Quit Stanbot (it holds the
  robot's one Wi-Fi viewer slot), then from an agent shell on the mini run
  `ssh malpern@openclaw.local 'cd ~/local-code/stanbot && git pull -q; python3 firmware/ota.py'`.
  It must print `"verified": true`. Reopen the app afterwards.
- **Agent shells on the mini cannot reach LAN hosts** (macOS Local Network
  privacy, no fix available). Route anything that talks to the robot over the
  network through `ssh malpern@openclaw.local`.
- **App:** `cd companion/StanbotCompanion && swift test && ./build-app.sh`,
  then `pkill -f Stanbot.app/Contents/MacOS/Stanbot; open build/Stanbot.app`.
- **Native firmware tests:** compile and run every `companion/test_*.cpp` with
  `c++ -std=c++17 -include initializer_list`. Python: `companion/test_*.py`.
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
