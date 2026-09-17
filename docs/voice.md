# Voice conversation (plan)

Written 2026-09-17 and revised the same day after a review. Phase 1, the
mouth, is built (see "Phase 1, as built"); the conversation is not. A Talk control in Stanbot opens a live spoken conversation with an
OpenAI voice model; the robot's face grows a mouth that moves while it speaks.
Audio comes from the Studio Display by default; the robot's microphone and
speaker are a separate, larger project.

## Decisions so far

- Model: `gpt-live-1` (recommended below; `gpt-realtime-2.1` is the fallback).
- Voice: male and expressive. `cedar`, one of the two voices OpenAI recommends,
  if `gpt-live-1` offers it; otherwise the closest male voice in Live's list.
  Expressive in delivery, still brief and calm in what it says.
- Text transcripts are kept in the logs (owner, 2026-09-17).

## Which OpenAI API

Checked against developers.openai.com on 2026-09-17. The beta Realtime
interface (`OpenAI-Beta: realtime=v1`, `response.audio.delta`) was removed on
2026-05-12, so most blog posts and Swift samples are out of date.

| | `gpt-live-1` | `gpt-realtime-2.1` (and `-mini`) |
| --- | --- | --- |
| Released | 2026-09-10 | 2026-07-06 |
| Turn-taking | Full duplex: listens while it speaks | Turns, with voice activity detection and barge-in |
| Billing | $0.05 per minute, per second, plus the backend model it delegates to | Audio tokens: $32 in, $64 out per 1M (mini $10 / $20) |
| Tools | Delegation: a Responses model reasons and calls tools, Live talks | Function calls in the session |
| Audio events | `session.input_audio.append`, `session.output_audio.delta` | `input_audio_buffer.append`, `response.output_audio.delta` |
| End of a spoken reply | No event: the client watches its own playback | `response.output_audio.done` |

**`gpt-live-1`.** Full duplex is what makes it feel like a presence at the
desk rather than a walkie-talkie, and it costs a predictable $3 an hour plus
the delegated model. The client talks to the model through one small protocol
(`VoiceModelClient`) so `gpt-realtime-2.1` can stand in if Live disappoints.

**Verified:** the model, its price and full duplex (model page), and the two
audio event names (migration guide). **Not yet verified:** endpoint, audio
format and sample rate, session length limit, voice list, and how the client
learns it has been interrupted. Spike (a) settles these.

**Transport: WebSocket.** WebRTC hides the audio inside media tracks, and
Stanbot needs the raw samples to choose the speakers and drive the mouth.

**Key and cost.** A dedicated OpenAI project key, `OPENAI_API_KEY_STANBOT`,
with a monthly budget set in the OpenAI dashboard, added through Add Secret and
read with sops as the robot passphrase is. It goes only in the `Authorization`
header, never in a URL, and the handshake is never logged. The app also stops a
conversation after 3 minutes with nobody speaking, and refuses to start once 60
minutes have been used that day (the inspector shows the minutes).

## Where the sound comes from

**Setting: Voice audio: Automatic / Studio Display / Robot.**

- **Automatic** (default): the Studio Display's microphone and speakers when
  both are present and running, otherwise the robot's.
- **Studio Display**: always that pair; refuses to start without it rather than
  falling back to the Mac mini's own speaker.
- **Robot**: the CoreS3's microphones and speaker.

Detection looks for the Core Audio devices ("Studio Display Microphone",
"Studio Display Speakers", both the defaults on the mini today) and checks they
are alive, since a sleeping display can stay listed. That is the mini in
practice, and also right if the Air is ever plugged into the display. Devices
are checked at each Start; if they disappear mid-conversation the conversation
ends with a plain reason instead of jumping to another speaker mid-sentence.

Until robot audio exists, Automatic without the display and the Robot setting
disable Talk, with the reason in its help text.

### Echo and other apps

Over WebSocket nothing cancels echo for us: without it the model hears itself
through the speakers and interrupts its own replies, and full duplex makes that
worse. `AVAudioEngine` with voice processing on the input node cancels what the
same engine plays. Separate input and output devices are normally fine for it
(FaceTime works that way); spike (b) confirms it with the Studio Display pair
before anyone assumes an aggregate device is needed.

**Voice processing ducks other apps by default.** On macOS 14 and later it dims
other applications' audio when it hears speech, which would quietly lower a
Meet call or music. Set `voiceProcessingOtherAudioDuckingConfiguration` to no
advanced ducking and the minimum level, and make "other audio is not ducked" a
pass criterion of spikes (b) and (c).

### Interruption

With full duplex and no end-of-reply event, the dangerous case is audio already
queued on the Mac: if seconds of speech are buffered, talking over Stanbot does
nothing until the queue drains. Keep the playout buffer at about 200 ms or less,
and find the event or rule that means "flush". Spike (a) cannot pass without
both, because they decide whether Live is usable at all.

## The app

- **Toolbar:** a Talk toggle at the right, beside Follow: `waveform` when off,
  `waveform` filled in the accent colour while a conversation runs. Nothing over
  the video. A failure (no key, no audio device, daily limit, network) shows as
  the window subtitle, as follow refusals do.
- **Robot menu:** Start Conversation / Stop Conversation, ⇧⌘T.
- **States:** off, connecting, listening, speaking, failed. **No automatic
  reconnect**, matching the rest of the app's motion and session habits: a
  dropped connection ends the conversation with a plain subtitle. Every way a
  conversation ends, including failures, closes the mouth.
- **Inspector, Voice section:** model, audio route, minutes this session and
  today, last error.
- **Settings, Voice:** audio route, voice, and a short persona (brief, plain,
  speaks when spoken to; warmth in the voice rather than in the word count).
- **Logs:** text transcripts and state changes in
  `~/Library/Logs/Stanbot/voice-*.log`. No audio is saved. The logs are
  unencrypted, like the follow logs.
- **The robot link:** voice never opens a second connection to the robot. The
  mouth rides the app's existing Wi-Fi link (see below); phases 0 and 1 need no
  robot at all.

## The robot during a conversation

- **Head following** carries on unchanged: it follows a face it sees, ends a
  session after 12 s without one and at its 3-minute cap, and starts again as
  usual. Nothing new is promised about looking at the speaker.
- **Light bar:** unchanged (blue with a face, orange breath without).
- **Eyes:** keep blinking; while Stanbot speaks they make no darting looks (a
  `speaking` flag into `GazeBrain`). No "listening" indicator on the robot: the
  macOS microphone indicator is the truthful one.

## The mouth

**Look.** Calm, in keeping with the eyes:

- No mouth when Stanbot is silent, so the resting face is exactly today's.
- While speaking, one soft rounded capsule centred under the eyes, in the eyes'
  grey (the irises stay grey since 2026-09-17; the light bar carries attention),
  a little dimmer than they are.
- Opening changes its height from a 3 px line to about 18 px and widens it a
  little (about 36 to 44 px). No teeth, tongue or lip shapes: loudness cannot
  tell sounds apart, and pretending looks worse than a simple mouth.
- Opening follows the envelope through a critically damped spring and grows in
  and fades out over about 150 ms.

**Signal.** The Mac computes a loudness envelope from the audio as it is
scheduled for the speakers (RMS over 20 ms, attack about 30 ms, release about
120 ms, gated below a noise floor), so a reply cut off by an interruption closes
the mouth too.

**Transport: not the command channel.** The robot reads text commands once per
camera loop, between frames (`pollNetworkCommands()` in the camera task and the
session capture task), and replies were measured at p50 121-160 ms and up to
about 430 ms (`docs/transport.md`). A 20 Hz mouth sent as `O,` lines would
arrive in bursts, and a short safety timeout would close the mouth between
bursts: a flapping mouth half a second behind the voice.

Instead, the mouth gets its own path: a UDP port read by a small dedicated
firmware task, which owns that socket alone (so the rule that one task owns the
TCP viewer socket still holds). Each datagram carries a sequence number and an
opening value; stale or out-of-order datagrams are dropped, and only packets
from the connected viewer's address are accepted. It only changes the display.
The Mac sends about 15 per second while speaking, and a final 0. If none arrive
for 400 ms the mouth eases shut, so a dropped link never freezes it mid-word.
The Mac also sends each value slightly early (the one-way Wi-Fi delay, measured
in phase 1) so mouth and voice line up.

**Drawing.** `StanbotEyes` already redraws the whole frame at up to about
30 fps from the main loop, so the mouth is one more rounded rectangle in the
same push; `max_eye_gap_ms` shows whether that costs anything. The mouth model
(clamping, easing, the 400 ms close) is a plain header, `mouth_model.h`, with
`companion/test_mouth_model.cpp` in the style of `test_gaze_brain.cpp`. The
app's `StanbotEyesView` draws the same mouth, and `CharacterTests` checks its
constants against the firmware as it already does for the eye poses.

## Phase 1, as built (2026-09-17, mouth revised the same day)

The first mouth (a capsule that appeared with speech and vanished after) looked
plain and abrupt. After research into robot and character mouths (m5stack-avatar,
Moxie, KITT, uLipSync, Rhubarb, OVRLipSync, ITU-R BT.1359 sync tolerances) the
owner chose a **shaping capsule that is always there**:

- **At rest** a thin grey line, 40x4 robot pixels, like the stock StackChan face.
- **Speaking** it opens with loudness (to 22 px tall, the corners drawing in as it
  opens) and changes shape with how bright the sound is: wider and flatter for
  "ee" and "s", narrower and rounder for "oo".
- **Pauses** under 400 ms keep the lips parted; after that it eases back to the
  line. A dip well below the recent peak closes it quickly, standing in for
  consonants. It never disappears.
- **Timing:** quick attack (40 ms), a 70 ms hold at each peak, slower release
  (150 ms). The picture leads the sound slightly (app 30 ms, robot 60 ms): people
  forgive a mouth that leads far more than one that lags.

Pieces:
- **Robot:** `MouthModel.h` (in `firmware/lib/StanbotEyes/src`) is the model and
  packet parser; `StanbotEyes` draws the mouth in its normal redraw; `mouthTask`
  in `camera_stream.ino` owns UDP port 3334 and queues accepted packets to the
  main loop. Packets (version 2: "SBMO", 2, opening 0-100, shape -100..100,
  sequence) are accepted only from the Wi-Fi viewer's address. `SBST` over USB
  reports `mouth_packets` and `mouth_rejected`.
- **Mac:** `Voice/MouthEnvelope.swift` does all the analysis: RMS for opening
  (floor -45 dBFS, full -10, tuned on a "Daniel" recording) and, for shape, the
  log of first-difference RMS over RMS (measured: "oo" about -2.4, ordinary
  vowels -1.3, "ee" and "s" toward 0). `Voice/SpeechMouth.swift` plays audio and
  drives both mouths; `Voice/MouthModel.swift` mirrors the firmware and
  `MouthTests` checks every constant against the header.
- **Look on the Mac:** a Metal `colorEffect` (`Shaders/StanbotMouth.metal`): a
  signed-distance capsule, soft edges, a faint lip highlight, a glow that bleeds
  past the rim and a dim inner light that rises with the voice.
- **Where it shows:** under the eyes of the large face (camera off), and in
  Stanbot's face in the title bar, left of its name (`RobotFaceBadge`): the
  CoreS3 front at toolbar size, light grey rim, black glass, the screen with the
  live eyes and mouth, and the copper camera ring. It is an AppKit titlebar
  accessory because SwiftUI's `.navigation` toolbar placement drew nothing in
  this window. Too small for the whole robot, so it is the face only.
- **Trying it:** Robot menu, Play Mouth Test. The line is rendered once with
  `say -v Daniel` and played through the default output (the Studio Display on
  the mini). Over Wi-Fi the robot's mouth moves too; over USB only the app's.
- **Render check** (shaders do not appear in window snapshots):
  `STANBOT_SHADER_LIBRARY=$PWD/build/Stanbot.app/Contents/Resources/StanbotShaders.metallib swift test --filter MouthTests/testMetalMouthDrawsARimAroundADarkOpening`
  writes `$TMPDIR/stanbot-mouth-{rest,ah,ee,oo}.png`.
- **Not yet seen:** the robot's mouth, its timing against the voice, and
  `max_eye_gap_ms` with the mouth drawing.

## Phases

1. **The mouth, with a recorded voice.** Firmware: the UDP mouth task, the model
   and the drawing (one flash, no motion). App: play a voice recording through
   the Studio Display and drive the mouth from it. Measure the lag by eye and
   `max_eye_gap_ms` for any display cost. Needs no API key, and proves the
   hardest timing problem first.
2. **Audio spikes on the Mac.** (b) Voice processing with the Studio Display
   pair: play speech, talk over it, confirm no echo reaches the capture and
   other audio is not ducked. (c) The same during a Meet call: the call's
   audio and microphone are unaffected, before, during and after.
3. **The Live spike.** (a) A command-line Swift client: open a `gpt-live-1`
   session with the key, talk through the Studio Display, print transcripts.
   Pass: the unverified facts above are settled, the playout buffer stays at
   about 200 ms, and talking over Stanbot stops its speech promptly.
4. **Conversation in the app.** `VoiceSession`, the Talk toggle, menu item,
   Settings, inspector, logs, idle stop and daily limit, wired to the mouth
   from phase 1. Tests: the envelope follower on synthetic samples; a fake
   robot (like `NetworkTransportTests`) asserting mouth datagram cadence and
   the closing 0; a fake model server for state transitions.
5. **Robot audio** (see below), only if still wanted after using phase 4.

## Robot audio: a separate project

The owner wants the robot's microphone and speaker as a setting and as the
fall-back. It is kept in scope, but it is a different architecture from
everything above, and should be planned on its own when it comes:

- The microphones (ES7210) and speaker amplifier (AW88298) are configured over
  the internal I2C bus, which the camera task owns exclusively; the main loop
  deliberately never calls `M5.update()`.
- Audio each way (16 kHz mono PCM16, about 32 kB/s) cannot travel on the current
  socket, which is serviced between roughly 200 ms JPEG encodes. It needs its
  own streaming path, like the mouth's but continuous, and a playout buffer on
  the robot against Wi-Fi jitter.
- Echo cancellation with the speaker centimetres from the microphones is a
  research spike of its own (ESP-SR's AEC is where to start).
- CPU is shared with JPEG capture, so camera frame rate during a conversation
  has to be measured.

## Open questions for the owner

- Create the dedicated OpenAI project key with a budget, or use the personal key?
- Is 3 minutes of silence the right idle stop, and 60 minutes the right daily limit?
