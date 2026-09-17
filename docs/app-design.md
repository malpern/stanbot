# Stanbot app design

The Mac companion app, redesigned 2026-09-16: a native macOS window built around
the robot's view, with a little of the robot's character in it.

## Structure

- **Waking is a shot from behind Stanbot's eyes.** The owner's brief: a
  first-person view of someone slowly opening their eyes in the morning. So it is
  a *sequence*, not an eased mask (`EyeAperture.swift`, `EyeMotionSequence`):
  2.4 s at launch (1.5 s when waking from a sleep the owner asked for, the same
  shot brisker); the lids come up with one half-blink on the way and then an
  unbroken rise (two blinks and a settle at the end read as bouncing); the
  right lid lags the left, so they are never in step; the picture is soft,
  washed out and drained of colour until the lids are well open, and focus
  arrives a beat after them; the aperture stays the shape of the robot's two
  eyes, where it draws them, for the first three quarters, then grows past the
  frame so the picture is simply there — sized to the frame, not to the eye
  pose, because a smiling expression's 26 px eyes once left the open aperture
  covering half the picture whenever a face was detected. The aperture is
  always the resting eye shape, whatever the expression. Falling asleep is the
  same machinery in
  1.1 s with one flutter on the way down. Every value is a pure function of
  time, so `EyeApertureTests` checks the blinks, the lag, the focus and the
  shape frame by frame, and can write a filmstrip (`STANBOT_WAKE_STRIP=1`). It
  is deliberately slower than the robot's own 0.7/0.4 s lids: the app is a
  cinema screen, the robot a face. The same waking plays at launch and whenever
  the camera comes back, so Stanbot's eyes open on the world rather than the
  picture popping in. While a sequence runs the picture is
  redrawn every frame from a `TimelineView`; at rest nothing animates. The last
  frame is held while the eyes close, because the robot stops sending as soon as
  it is asked to sleep, and the app stops analysing once they are shut. Reduce
  Motion fades instead.
  A sequence interrupted by another (Sleep clicked mid-wake, or the reverse)
  carries on from where the eyes are, blended over 0.3 s, rather than snapping
  to the new sequence's start; and the robot's report of its sleep state is
  ignored when it contradicts a command sent in the last two seconds, since
  that is the earlier state arriving late (together these made a click mid-wake
  open, close and open the eyes again).
  Two things this depends on, both learned by breaking them (2026-09-17): the
  veil is applied to the **picture**, not the pane around it (on the pane the
  eyes centre on the window and sit below the letterboxed video), and it keeps
  **one view tree at every state** — an `if` that skipped the mask while awake
  made SwiftUI rebuild the subtree on sleep, so the picture cut straight to black
  with no animation at all.
- **The robot's view is the window.** The camera fills the width at the top of
  the window (not centred, so it stays put as the window grows), with the
  selected face outlined. No sidebar: there is one robot and no
  hierarchy to navigate. If several robots or recorded sessions arrive, a
  sidebar comes back with real places in it.
- **Title bar:** Stanbot's live eyes and mouth (only while the controls panel
  is hidden — one Stanbot on screen, not two), its name, and the red dot when
  it cannot be reached (no icon for a working link: nothing to say) — all one titlebar
  accessory (`RobotFaceBadge`); the window's own title is a single space so the
  dot can sit right of the name. (Hiding the title instead, with
  `titleVisibility`, let the content slide up under the toolbar: the video was
  cut off and the panel's top was out of view, 2026-09-17.) Hovering says what is wrong; the panel says the
  same in words. The link, firmware and the rest of the read-only detail is in
  Diagnostics.
- **Toolbar (2026-09-17):** Sleep/Wake and the Controls toggle. Follow/Stop lives in the panel (and in the Robot menu, ⌘.).
- **Nothing over the picture.** Controls live in a panel on the right.
- **Controls panel** (right, hideable, remembered, ⌥⌘I): Stanbot's face large
  (the CoreS3 front, `RobotFace`) with its mood caption, and a gear in the
  corner, and it scrolls, so nothing is ever pushed out of view at small window
  sizes. The caption is left out while the video area's empty state carries
  the same message in bigger type. **Clicking the face puts the robot to sleep or wakes it**: on the
  robot the eyes close over 0.7 s before the screen darkens
  (`SleepCurtain.h`), and the light bar goes off while it sleeps; waking opens
  them again over 0.4 s while the light bar comes up from dark over 0.6 s
  (`LightBar::wake`), orange rising the instant the robot wakes — before the app
  has restarted the camera — so the light wakes with the eyes. An orange
  line appears above the face when something is wrong (unreachable, or a refusal
  that will not clear). Nothing else: the panel is Stanbot, not a control board.
- **The gear sheet** holds everything else, in four sections: Head (Follow/Stop
  and Sleep/Wake, Follow automatically, the round direction pad), Camera (show
  the camera, mirror), Expression (all 18 faces, nine across), Connection (the
  method, what it is using, Reconnect). The mouth test is in the Robot menu, and
  app preferences stay in Settings (⌘,).
- **Diagnostics window** (Window menu, ⌥⌘D): live status (link, firmware and its
  warnings, passphrase, following, limits, camera, face, facing), the recent
  follow sessions read from their logs with each result and a Show button, and
  the activity log with Copy. Kept out of the main window and out of Settings,
  which holds only preferences.
- **Settings** (⌘,) in tabs: General (follow automatically, firmware-change
  sound), Connection (transport, USB device, Reconnect, Reboot, passphrase),
  Video (mirror, enhancement).
- **Menus:** a Robot menu (Follow ⇧⌘F, Stop ⌘., Follow Automatically, camera
  ⌘K, Expression, Play Mouth Test, Reconnect ⌘R, Reboot Robot), Show/Hide
  Controls ⌥⌘I in View, Diagnostics ⌥⌘D in Window.

## Character

- **One face on both screens.** `StanbotEyesView` draws the same two eyes the
  robot draws on its own display, with the firmware's poses value for value
  (`CharacterTests.testEyePosesMatchTheFirmware` parses `StanbotEyes.h`). The
  eyes blink, drift when idle, turn cyan when attending, look toward the
  selected face in the window, and close into two soft curves when Stanbot is
  asleep. Expression changes slide with a critically damped spring; Reduce
  Motion stops the drift and the springs.
- **Mood from facts.** `Mood.of` turns connection, camera, face selection and
  follow state into an expression and a short caption: "Asleep", "Waking up…",
  "Looking around", "Is someone there?", "I see someone", "Following you",
  "Where did you go?", "Something’s wrong" — which is the **trouble face**, after
  the Sad Mac: two crossed-out eyes where the eyes were and a frown below, in
  the same grey, still. The robot draws the same (`StanbotEyes::drawTrouble`,
  emotion `trouble`) on its own screen for 12 s after a follow session that
  ended in a fault, then returns to whatever expression was chosen; normal
  endings (idle, deadline, stopped) do not trigger it. Empty states use the same face,
  large, with the one action that helps ("Stanbot is asleep", Reconnect).
- **Rounded type** only where Stanbot speaks (captions, empty-state titles,
  face labels); the system font everywhere else. The accent is the robot's eye
  cyan, softened.

## Small moments

Each is tied to something that really happened, lasts well under a second, is
interruptible, and is skipped or reduced to a fade under Reduce Motion.

| When | What Stanbot does |
| --- | --- |
| Looking for the robot | Eyes glance side to side ("Waking up…"). No spinner: the eyes are the loader. |
| Connected | Eyes flutter open (`wake`). |
| Camera starting | Squints ("Opening my eyes…"); the video then clears in from a blur, like eyes focusing. The empty state says it once — the right-hand panel drops its caption whenever the two would say the same words. |
| A face is selected | Eyes widen and lift (`surprise`); the face outline draws itself around the face and its label pops up from the top edge, once per person. |
| While following | Eyes attend (cyan) and look toward the face; Follow morphs into a red Stop in place, and the "Head powered" dot pulses. |
| Session ends normally | A slow double blink (`content`). |
| Refused or failed | A small head shake (`shake`) with a worried look; the message stays literal. |
| New firmware | A happy pulse (`sparkle`), alongside the existing chime. |
| No one for 90 s | "Getting sleepy…": sleepy eyes, still awake, camera still on. |
| Pointer over the face | The eyes follow the pointer. Click: a little giggle bounce. |
| Choosing an expression | The menu shows Stanbot's own eyes for each expression, not words alone. |

Reactions are tables of six keyframes (`Reactions.swift`), and which one fires
for a change is a pure rule (`ReactionFacts.reaction`), both tested.

## Gaze: looking away, then looking at you

Both faces (the robot's and the Mac's) use the same idea of gaze:

**Calm first (2026-09-17).** The robot sits on the desk in front of its owner
all day, so the eyes must never pull attention. The first tuning was lively
and accurate to people (20 ms jumps every 1-2.6 s across most of the screen,
quarter-second glances, a twitch every second while locked on, blinks every
5-8 s on the Mac) and it was a distraction. Both faces now:

- **Nobody there:** slow glides (speed-capped, about half a second to a second)
  between resting points a little either side of centre, each held 5-10 s.
  About one move every seven seconds.
- **Someone there, not facing Stanbot:** resting a little away from them and
  slightly down, with a rare, unhurried look at them (6% of fixations, held
  1.5-2.5 s; about 2% of the time overall).
- **Someone facing Stanbot for a moment** (`EngagementTracker`: head turned
  toward the camera for 0.4 s; let go after 0.8 s turned away or gone; faces
  too small to judge hold the state): the eyes settle on them and follow smoothly,
  with tiny micro-saccades, and the pupils dilate by about 38%, quickly. When
  the person turns away, the pupils relax slowly.

Robot: `firmware/lib/StanbotEyes/src/GazeBrain.h`, tested natively by
`companion/test_gaze_brain.cpp`. The app sends `G,<x>,<y>,<engaged>`; the flag
lapses 900 ms after the last line, and gaze is now sent during follow sessions
too.

Mac, the fuller version (`StanbotEyesView`): the same planner
(`GazePlanner`, tested) plus a small recognition widening as the eyes lock on,
one slow soft blink about two seconds later, fewer blinks while attending, eyes
drawn slightly together when the face is close (vergence, from face size),
lids that lower when looking down, and two catchlights that lag the pupil
slightly. Under Reduce Motion the eyes stay still and centred unless locked on.

**Eyes lead, head follows (robot, during follow sessions).** The eyes jump
in tens of milliseconds and the head eases over hundreds, so the eyes reach a
person first. While the head turns, the eyes aim where the face is now rather
than where it was in the ~300 ms old camera frame: the session corrects them
for the head's motion since that frame (`head_eye.h`), so the gaze holds on the
person as the eyes return to centre, like the counter-rotation of a person's
eyes. In a simulated loop that cuts the gaze error while turning from 42 raw
(worst) to 6. A turn toward a new goal of about 15 degrees or more brings a
blink with it. The follow trace records `eye_x`, and the replay chart plots
where the eyes aimed next to the head. The Mac eyes do not mirror this yet:
the app only learns the head's motion from telemetry after a session.

This is expression, not perception: "engaged" means a face turned toward the
camera, the caption is "Looking at you" (what Stanbot does), and nothing claims
eye contact. In the title bar the eyes are small, too small for dilation and
catchlights to read; they show fully where the face is drawn large.

## The screen look (Metal)

The eyes glow a little and, when drawn large, carry a faint LCD pixel grid with
red/green/blue subpixel stripes, so the Mac face reads as the robot's own
screen. The grid is a SwiftUI `colorEffect` backed by a Metal function,
`Shaders/StanbotScreen.metal`; `build-app.sh` compiles it into
`Stanbot.app/Contents/Resources/StanbotShaders.metallib`. Without that file
(`swift test`, `swift run`) the effect is simply off. The glow is a SwiftUI
shadow on the lit irises. Both are off with Increase Contrast; the grid only
appears on eyes at least 120 pt wide and not while scanning.

Metal is used only here, deliberately: video display, eye drawing and vision
already run on the GPU through SwiftUI, VideoToolbox, Vision and Core ML, and
none of them was a bottleneck.

Checking it: the window snapshot cannot capture shader effects, so an opt-in
test renders the real eyes with and without it and measures the grid:

```sh
STANBOT_SHADER_LIBRARY=$PWD/build/Stanbot.app/Contents/Resources/StanbotShaders.metallib \
  swift test --filter CharacterTests/testScreenLookDrawsTheLCDGrid
```

## What it costs

Measured 2026-09-16 on the mini in preview mode (a still preview image, so
video decoding is not included), 20 one-second `top` samples after 5 s. Energy
impact tracked CPU in every row.

| Scenario | First redesign | Now |
| --- | --- | --- |
| Asleep | 0.1% CPU | 0.1% |
| Connecting (large and small eyes scanning) | 13.4% | 6.8% |
| Connected, camera off (large eyes idle) | 11.0% | 4.9% |
| Seeing someone | 9.0% | 0.5% |
| Following | 9.8% | 1.1% |
| Someone there, not facing (shy glances) | n/a | 1.6% |
| Someone facing Stanbot (locked on) | n/a | 0.8% |

What mattered, in order:
- **A 30 fps clock** drove the eyes even when nothing moved (about 9% on its
  own). Blinks, glances and scanning are now state changes, animated by
  SwiftUI, a few times a second at most.
- **A repeating pulse** on the Head powered dot cost about 9% for a whole
  session. It now bounces once when power comes on.
- **Constant idle wander** animated about 60% of the time (about 10% with the
  large eyes). It is now a short glance every 4 to 7 seconds.
- **The LCD grid** costs about 4% while the eyes move, nothing while they are
  still; it is skipped while scanning. The glow cost nothing measurable.

Check any new continuous animation the same way:
`top -pid <pid> -stats pid,cpu,power`.

## Rules the personality must not break

- **Safety surfaces stay plain.** Stop, "Head powered", the follow confirmation
  and refusals are literal and never cute.
- **No claims about perception or feelings.** A face is "someone"; a face
  turned toward the camera is "Facing Stanbot" or "Turned toward the camera:
  Roughly", never eye contact. `testNoCaptionClaimsEyeContact` guards the
  captions.

## Looking at it without a robot

```sh
cd companion/StanbotCompanion && ./build-app.sh
open -n --env STANBOT_PREVIEW=seeing build/Stanbot.app      # asleep | connecting | connected | seeing | shy | engaged | following | refused
open -n --env STANBOT_PREVIEW=following --env STANBOT_SNAPSHOT=/tmp/stanbot.png build/Stanbot.app
```

`STANBOT_ICON_SHEET=/tmp/icons.png swift test --filter CharacterTests/testWriteExpressionIconSheet`
writes every expression icon to one image.

A snapshot run quits as soon as the picture is written, so it leaves nothing on
screen; add `-g` to `open` to keep it in the background as well.

`STANBOT_PREVIEW=sleeping` is "seeing" and then falls asleep after a second, and
`waking` the reverse, so `STANBOT_SNAPSHOT_DELAY=1.3` photographs the eyes part
way through — which is how the two bugs above were found, and how the wake
sequence was checked end to end.
`STANBOT_SNAPSHOT_WINDOW=Diagnostics` opens and captures that window instead,
`=sheet` captures an open sheet, and `STANBOT_WINDOW_SIZE=1800x1100` checks a
layout at another size.
The snapshot is taken 3 s after launch, which can catch the eyes mid-reaction.

`STANBOT_PREVIEW` fills the model with made-up state and opens no USB, Wi-Fi or
camera, so nothing can move. `STANBOT_SNAPSHOT` makes the preview write its own
window to a PNG after 3 s. That snapshot does not draw Liquid Glass, and the
preview's link reads "USB (No USB device)"; judge glass and the real link on
the live app.

## Not done yet

- Settings is still one long form; splitting it into tabs is next.
- Not yet seen live: glass over real video, the eyes at the control bar's
  size on a Retina display, light appearance for the inspector.
