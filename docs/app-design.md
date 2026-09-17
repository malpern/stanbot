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
open -n --env STANBOT_PREVIEW=seeing build/Stanbot.app      # asleep | connected | seeing | following | refused
open -n --env STANBOT_PREVIEW=following --env STANBOT_SNAPSHOT=/tmp/stanbot.png build/Stanbot.app
```

`STANBOT_PREVIEW` fills the model with made-up state and opens no USB, Wi-Fi or
camera, so nothing can move. `STANBOT_SNAPSHOT` makes the preview write its own
window to a PNG after 3 s. That snapshot does not draw Liquid Glass, and the
preview's link reads "USB (No USB device)"; judge glass and the real link on
the live app.

## Not done yet

- Settings is still one long form; splitting it into tabs is next.
- Not yet seen live: glass over real video, the eyes at the control bar's
  size on a Retina display, light appearance for the inspector.
