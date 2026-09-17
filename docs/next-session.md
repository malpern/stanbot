# Next session at the robot

One page for the next time someone is at the robot and at the mini. Written
2026-09-16, updated 2026-09-17. On the robot: calibration + pitch build
`c6b9ad3` (yaw +-48, pitch following on, search, easing, renewable power lease,
telemetry check, review fixes, and the new gaze: looking away until someone
faces Stanbot, then locking on with dilated pupils; eyes corrected for head
motion; a blink with big turns). Flashed and verified over Wi-Fi. The Stanbot app in `companion/StanbotCompanion/build/Stanbot.app` was
rebuilt from the latest commit (adds the desk camera toggle, off) and has not been launched since.

Stay at the robot for every step that moves it. Stop in the app (or unplug the
robot) if anything looks wrong.

## 0. Before anything moves (2 min)

- [ ] Find the USB port: `ls /dev/cu.usbmodem*`
- [ ] Open the app. Firmware card shows the commit you just flashed, and lists "tilts up and down".
- [ ] **Turn Automatic off** in Head following before step 1. Otherwise a
      session starts as soon as it sees a face.

## 1. Find level for pitch (5 min)

Pitch following currently returns to wherever each session happened to start,
because no level position has been confirmed.

- [ ] Quit the app (the finder needs the USB port to itself).
- [ ] `python3 companion/find_pitch_level.py /dev/cu.usbmodemXXXX`
- [ ] Answer u / d / l for each hold (at most seven). It reboots the robot
      between steps, which takes a few seconds.
- [ ] Note the value it prints. Leave `head_tracker.h` alone for now (that is
      a code change for afterwards; step 2 does not depend on it).

Pass: it ends with "Level looks like raw N". Stop if any step prints an error
or a refusal, and do not retry automatically.

## 2. First session on this build (10 min)

- [ ] Reopen the app, stream on, Automatic still off.
- [ ] Press Follow and confirm. Sit in front of the robot.

Watch for, and note yes or no:

- [ ] **Up and down:** raise and lower your head; the head tilts toward you.
- [ ] **Eyes:** the drawn pupils look toward you, not away. (Mirroring is an
      assumption; if they look away, note it.)
- [ ] **Search:** step out of view to one side. The head holds, glances that
      way, sweeps back, then returns within about 5 s.
- [ ] **Continuous:** stay in view for 40 s or more; the session does not end
      at 20 s.
- [ ] **Ending:** leave for 15 s; it ends by itself ("No face for 12 seconds").
- [ ] **No hunting:** the head does not swing back and forth on a still face.
- [ ] **Looking away, then at you:** before you face it, the robot's eyes
      wander and mostly look away, with brief glances at you. Face it for a
      moment: the eyes lock on and the pupils visibly widen. Turn away: they
      relax slowly and look away again. (Also works with the camera on and no
      session running.)
- [ ] **Eyes lead the head:** move to one side. The eyes get there first, and
      as the head turns they stay on you instead of swinging past.
- [ ] **Blink with a big turn:** step well to one side; a blink comes with the
      turn.

Afterwards:

- [ ] `python3 tools/follow_replay.py ~/Library/Logs/Stanbot/follow-<newest>.log`
      and open the HTML beside it. Telemetry should read `verified`. The yaw
      chart's orange "eyes aim" line should sit on the person while the blue
      head line catches up.

## 3. Widen yaw one step (10 min, only if step 2 looked clean)

- [ ] Quit the app. `STANBOT_FOLLOW_CALIBRATION=1 STANBOT_FOLLOW_PITCH=1 STANBOT_FOLLOW_YAW_RANGE=96 firmware/build.sh`
- [ ] `python3 firmware/ota.py` from Terminal on the mini, app closed. It must
      print `"verified": true` and `"follow_yaw_range": 96`.
- [ ] Repeat step 2's session, moving further to each side. Watch that the head
      never meets the body. Replay the log.

## 4. Wi-Fi only (10 min, optional)

- [ ] Move the cable to the back (power-only) port. Open the app on Wi-Fi.
- [ ] Follow, Stop and a short session work; telemetry reads `verified`.
- [ ] Turn Wi-Fi off on the Mac for a few seconds mid-session: the head
      searches, returns, and the session ends by itself.

## 5. On the next Google Meet call (5 min, independent of the robot)

- [ ] `tools/desk_camera/probe.sh --seconds 120` in the three cases in
      [desk camera](desk-camera.md) step 1: call first, probe first, Center
      Stage toggled mid-call.
- [ ] Watch the self-view for framing, resolution or freezes; note
      `format_or_rate_changed` at the end.
- [ ] Only if all three were clean: Settings, Desk camera, turn on "Log the
      Studio Display camera during sessions" (macOS asks for camera access
      once), and repeat one case with the app running instead of the probe.

## Hand back

Tell Claude: the level value from step 1, the yes/no list from step 2, and
the log file names. Next code changes then follow from those: setting
`pitchRest`, fixing the eye mirror if needed, and the next yaw step.
