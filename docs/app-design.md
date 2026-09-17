# Stanbot app design

The Mac companion app, redesigned 2026-09-16: a native macOS window built around
the robot's view, with a little of the robot's character in it.

## Structure

- **The robot's view is the window.** The camera fills it, letterboxed on
  black, with the selected face outlined. No sidebar: there is one robot and no
  hierarchy to navigate. If several robots or recorded sessions arrive, a
  sidebar comes back with real places in it.
- **Title and subtitle:** "Stanbot", with the link and firmware commit as the
  window subtitle.
- **Toolbar:** camera on/off, the expression menu, the connection menu, and
  the inspector toggle.
- **Floating control bar** (Liquid Glass on macOS 26, a material before):
  Stanbot's face and a caption, then Follow (or Stop while following, with a
  red "Head powered" timer), and the Automatic toggle.
- **Inspector** (right, hideable, remembered): Robot, Head, Seeing, Session,
  Activity. The detail that used to be six status cards.
- **Menus:** a Robot menu (Follow ⇧⌘F, Stop ⌘., Follow Automatically, camera
  ⌘K, Expression, Reconnect ⌘R, Reboot Robot) and Show/Hide Inspector ⌥⌘I in
  View.

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
  "Where did you go?", "Something’s wrong". Empty states use the same face,
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
| Camera starting | Squints ("Opening my eyes…"); the video then clears in from a blur, like eyes focusing. |
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
eye contact. In the control bar the eyes are 56 pt, too small for dilation and
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

`STANBOT_PREVIEW` fills the model with made-up state and opens no USB, Wi-Fi or
camera, so nothing can move. `STANBOT_SNAPSHOT` makes the preview write its own
window to a PNG after 3 s. That snapshot does not draw Liquid Glass, and the
preview's link reads "USB (No USB device)"; judge glass and the real link on
the live app.

## Not done yet

- Settings is still one long form; splitting it into tabs is next.
- Not yet seen live: glass over real video, the eyes at the control bar's
  size on a Retina display, light appearance for the inspector.
