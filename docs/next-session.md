# Next session

Handoff written 2026-09-17, replacing the earlier checklist (its pitch-level,
Wi-Fi and first-session steps are done). Everything below is committed and
pushed; `main` was clean at `84661e7`.

## State right now

**On the robot:** firmware `ba9e961`, a calibration build made with
`STANBOT_FOLLOW_CALIBRATION=1 STANBOT_FOLLOW_PITCH=1 STANBOT_FOLLOW_YAW_RANGE=96`,
flashed over Wi-Fi and verified (`V` reports `follow_limits_measured:true`,
`follow_pitch:true`, `follow_yaw_range:96`). Later commits changed only the app.

- **Yaw** +-96 raw (~30 deg) around 460. Operator: "left and right looking good".
- **Pitch** level measured by eye at raw **614** (`calibration-pitch-level.jsonl`).
  Limits 594..870. Down: 582 was tried 2026-09-17; the head stopped at 592,
  10 short and pressing, looking nearly straight down to the owner, so the
  minimum is the unpowered rest, 594. That look does not fit ~3 raw/deg from
  level 614: re-check level before changing pitch again. Up was verified 2026-09-17: steered all the way up, the head
  met a hard stop at ~885 that the owner saw as vertical (`stall_detected`,
  power off verified), so pitch is ~3.0 raw/deg and the maximum is 870, 15 short
  of the stop. Unpowered the head droops to 594, accepted as a start and never
  pushed lower. A head left resting above 870 is refused until lowered by hand.
- **Following** is continuous: sessions repeat without reboots (3 s cooldown),
  each on a renewable power lease with a 3-minute hard maximum, and end after
  12 s with no face. Corrections use the head position when the frame was
  taken (frame sequence numbers), 60% gain, which stopped the hunting.
- **Manual steering:** `H,<seq>,<x>,<y>` from the app's joystick or arrow
  keys; steering wins over faces, holds after 300 ms without input, hands back
  to following 1.5 s after release.
- **Light bar:** soft blue while a face is attended to; a gentle orange breath
  (5 s) while the camera streams with no face; dark otherwise. The eyes stay
  grey. Confirmed by the owner 2026-09-17.
- **Eyes:** calm tuning (slow glides, 5-10 s holds, rare looks).
- **Wi-Fi security:** only stream/display commands and `C,UNFOLLOW` are
  accepted over Wi-Fi; `C,FOLLOW` and `C,REBOOT` need an HMAC challenge keyed
  by the OTA passphrase; OTA requires the passphrase. The app reads it from
  `~/dotfiles/secrets.env` with sops (not the Keychain: its permission dialog
  was unwanted).

**The Stanbot app** (`companion/StanbotCompanion/build/Stanbot.app`, rebuilt
from `84661e7`): video fills the window, mirrored by default; toolbar top right
has a red dot (only when the robot is unreachable for 3 s, details on hover),
the direction-pad joystick, and Follow/Stop. Settings: transport (Wi-Fi with USB
fallback by default), Follow automatically (on at every launch; Stop pauses it
until the next launch), firmware-change sound (Purr), video enhancement,
mirror. Toolbar, direction pad and mirroring confirmed by the owner 2026-09-17.

**Cable:** the owner moved it to the back (power-only) port. Everything works
over Wi-Fi except `companion/find_pitch_level.py` and other USB probes, which
need the side (head) port.

## Next, in order

1. **Done 2026-09-17:** light bar, toolbar, mirroring confirmed; vertical
   verified (stop at ~885, maximum now 870). Also watch for a repeat of the one
   `position_status_error` so far (yaw servo stopped answering at pitch 710,
   session ended safely); if it recurs at high pitch, suspect cable tension.
2. **Widen pitch down** in 16-raw steps, watching for the head meeting the body.
   Stopped at 594 (the rest). First re-check level: steer until the face looks
   straight ahead and read pitch from the follow log.
3. **Widen yaw** one supervised session per step:
   `STANBOT_FOLLOW_YAW_RANGE=144`, then 192, 240, 288 (the most ever swept).
4. **When calibration is done**, decide whether `measured` can be true in the
   normal build rather than only in calibration builds.
5. **Voice conversation: planned** in `docs/voice.md` (OpenAI `gpt-live-1`,
   Studio Display audio, a male expressive voice, transcripts kept, a mouth on
   the robot over its own UDP path). Nothing built; phase 1 is the mouth with a
   recorded voice.
6. **Gaze: paused.** Nothing has been measured. If gaze matters for a feature,
   first build a 2-minute prompted test (look at robot / screen / away) that logs
   the robot-only engaged flag against the prompt. See `docs/gaze.md`. The Studio
   Display (desk) camera code was removed 2026-09-17 to keep the app to the
   robot's camera; `92ab70b` is the last commit with it (`DeskCamera.swift`,
   `tools/desk_camera/`, `docs/desk-camera.md`) if it is ever wanted back.

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
  SBPD trace, SBMV result, SBPW power). `tools/follow_replay.py` renders one.
- **Safety:** stay supervised for anything that moves or widens limits. Never
  retry a refusal automatically. `DISABLE LATCH NOT VERIFIED` means power the
  robot off by hand (hold its button; it has a battery). Quit Stanbot before
  USB motion tools, or automatic following can start a session underneath them.

## The owner's preferences, learned this week

Calm over lively: the robot sits in front of them all day, so no fast eye
motion, no bright or flashing light. Native Mac design, nothing floating over
the video. Plain safety signals. Wants things done and verified, reported
briefly.
