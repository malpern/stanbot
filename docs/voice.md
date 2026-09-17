# Voice conversation (plan)

Written 2026-09-17. Nothing here is built yet. A Start/Stop control in Stanbot
opens a live spoken conversation with an OpenAI voice model; the robot's face
grows a mouth that moves while it speaks. Audio is the Mac's by default, the
robot's only when chosen or when the Mac has no good audio.

## Which OpenAI API

Checked against developers.openai.com on 2026-09-17. The beta Realtime
interface (`OpenAI-Beta: realtime=v1`, `response.audio.delta`) was removed on
2026-05-12, so most blog posts and Swift samples are out of date.

| | `gpt-live-1` | `gpt-realtime-2.1` (and `-mini`) |
| --- | --- | --- |
| Released | 2026-09-10 | 2026-07-06 |
| Turn-taking | Full duplex: listens while it speaks | Turns, with voice activity detection and barge-in |
| Billing | $0.05 per minute, per second, plus the backend model it delegates to | Audio tokens: $32 in, $64 out per 1M (mini $10 / $20) |
| Tools | Delegation: a Responses model does the reasoning and tool calls, it talks | Function calls in the session |
| Audio events | `session.input_audio.append`, `session.output_audio.delta` | `input_audio_buffer.append`, `response.output_audio.delta` |
| End of a spoken reply | No event: the client watches its own playback | `response.output_audio.done` |

**Recommendation: `gpt-live-1`.** Full duplex is what makes it feel like a
presence at the desk rather than a walkie-talkie, and a conversation costs a
predictable $3 an hour plus the delegated model. Its missing "done speaking"
event does not matter here: the mouth is driven by what the Mac actually plays,
not by model events. The client talks to the model through one small protocol
(`VoiceModelClient`) so `gpt-realtime-2.1` can stand in if Live disappoints.

**Transport: WebSocket, with the API key.** WebRTC is OpenAI's advice for
browsers, but it hides the audio inside media tracks, and Stanbot needs the raw
samples both to pick the speakers and to drive the mouth. Ephemeral client
secrets exist to keep keys out of untrusted clients; this key never leaves the
owner's Mac. It is `OPENAI_API_KEY_PERSONAL` in `~/dotfiles/secrets.env`, read
with sops the way the robot passphrase is, and never logged.

Details to confirm in the first spike: Live's endpoint, audio format and
sample rate (Realtime uses 24 kHz mono PCM16), session length limit
(Realtime's is 60 minutes) and how interruption is reported.

## Where the sound comes from

**Setting: Voice audio: Automatic / This Mac / Robot.**

- **Automatic** (default) uses the Studio Display's microphone and speakers
  when both are present, otherwise the robot's. On the mini they are the
  system defaults today.
- **This Mac** always uses the Studio Display pair, and refuses to start
  without it rather than silently using the Mac mini's own speaker.
- **Robot** uses the CoreS3's microphones and speaker.

The detection looks for the devices ("Studio Display Microphone", "Studio
Display Speakers" in Core Audio) rather than the machine name. On the mini
that is the same answer; it also does the right thing if the Air is ever
plugged into the display, or the display is off. The devices are re-checked
at each Start and when Core Audio reports a device change mid-conversation; if
the display vanishes, the conversation stops with a plain reason rather than
jumping to another speaker mid-sentence.

Until robot audio exists (phase 3), Automatic without a Studio Display and the
Robot setting disable Start, with the reason in its help text.

### Echo is Stanbot's problem

Over WebSocket nothing cancels echo for us: without it the model hears itself
through the speakers and interrupts its own replies, and full duplex makes
that worse. On the Mac, `AVAudioEngine` with voice processing on the input
node cancels what the same engine plays. The open question, and the first
spike, is whether voice processing works with the Studio Display's microphone
and speakers being two separate Core Audio devices (it may need an aggregate
device).

### A video call

The Studio Display camera experiment was dropped partly over risk to Meet
calls, and the microphone has the same shape. A conversation only runs while
the owner has pressed Start, and macOS shows its microphone indicator, but
the spike should still check that starting and stopping a conversation during
a Meet call leaves the call's audio alone (voice processing can change device
modes).

## The app

- **Toolbar:** a Talk toggle at the right, beside Follow: `waveform` when off,
  `waveform` filled in the accent colour while a conversation runs. Nothing
  over the video. A failure (no key, no audio device, network) shows as the
  window subtitle, as follow refusals do.
- **Robot menu:** Start Conversation / Stop Conversation, ⇧⌘T.
- **States:** off, connecting, listening, speaking, stopping, failed. The
  inspector gains a Voice section: model, audio route, minutes this session,
  last error.
- **Stops by itself** after 3 minutes with nobody speaking, so a forgotten
  conversation does not bill all afternoon, and at the session limit.
- **Settings, Voice:** audio route, voice (OpenAI suggests `marin` or `cedar`),
  and a short persona. The default persona follows the owner's preferences:
  calm, brief, plain, speaks only when spoken to.
- **Logs:** text transcripts and state changes to
  `~/Library/Logs/Stanbot/voice-*.log`. No audio is saved.
- **Head following** keeps running during a conversation, so Stanbot looks at
  whoever is talking to it.

## The mouth

**Signal.** The Mac computes a loudness envelope from the samples as they are
handed to the speakers (a tap on the player: RMS over 20 ms, a quick attack
of about 30 ms and a slower release of about 120 ms, gated below a noise
floor), so the mouth stays in step with what is heard, including when a reply
is cut off. It sends `O,<0-100>` to the robot about 20 times a second while
the value changes, and `O,0` when playback stops. `O,` joins the Wi-Fi command
allowlist in `network_policy.h`: like `E,` and `G,` it only changes the
display.

**Safety net on the robot.** If no `O,` arrives for 250 ms the mouth eases
shut by itself, so a dropped link never leaves the robot frozen mid-word (the
same idea as manual steering's hold timeout).

**Look.** Calm, in keeping with the eyes:

- No mouth at all when Stanbot is not speaking, so the resting face is exactly
  today's.
- While speaking, one soft rounded capsule centred under the eyes, in the eyes'
  grey (cyan when attending, like the eyes), a little dimmer than they are.
- Opening changes the capsule's height, from a 3 px line to about 18 px, and
  widens it slightly (about 36 to 44 px) as it opens. No teeth, no tongue, no
  lip-sync shapes: an envelope cannot tell vowels apart, and pretending would
  look worse than a simple mouth.
- Opening follows the envelope through a critically damped spring, so it never
  snaps; the mouth grows in and fades out over about 150 ms at the start and
  end of speech.
- While Stanbot speaks, the eyes keep blinking but make fewer darting looks.

**Where it is drawn.** `StanbotEyes` gains `setMouth(open, now)` and draws the
mouth in the same full-frame redraw it already does at about 30 fps, so it
adds no extra display pushes. The app's `StanbotEyesView` draws the same mouth
from the same constants, and `CharacterTests` checks them against
`StanbotEyes.h`, as it already does for the eye poses. A host test covers the
mouth model: clamping, easing, and the 250 ms fall-back to closed.

## Robot audio (later)

This is real firmware work and comes last.

- The CoreS3 has two microphones (ES7210) and a speaker amplifier (AW88298),
  both configured over the internal I2C bus, which the camera task owns
  exclusively today. Their setup has to run from that task, or ownership has
  to be shared carefully.
- Audio would travel in the existing stream: 16 kHz mono PCM16, about
  32 kB/s each way, which Wi-Fi carries easily. Robot to Mac is a new binary
  packet beside `SBFR` frames. Mac to robot needs a binary frame in a command
  channel that is text lines today. The Mac resamples between 16 and 24 kHz.
- The robot needs a playout buffer of about 100 ms against Wi-Fi jitter, and
  in this mode drives its own mouth from what it plays, instead of `O,`.
- Echo cancellation on the robot is harder than on the Mac (the speaker is
  centimetres from the microphones); the ESP-SR AEC is the place to look.
- CPU is shared with JPEG capture, so camera frame rate during a conversation
  has to be measured, not assumed.

## Phases

0. **Spikes (no robot needed).** (a) A command-line Swift client that opens a
   `gpt-live-1` session with the key, speaks through the Studio Display and
   prints transcripts. (b) Voice processing with the Studio Display pair: play
   speech, talk over it, confirm the model does not hear itself. (c) Start and
   stop it during a Meet call.
1. **Conversation on the Mac.** `VoiceSession`, the Talk toggle, the menu
   item, Settings, logs, idle stop. Robot route disabled.
2. **The mouth.** Firmware `O,` and the mouth drawing (one flash, no motion),
   then the app's envelope and face. Can be tested before phase 1 by playing a
   recorded voice.
3. **Robot audio** and the real Automatic fall-back.
4. **Later:** delegated tools that let the conversation act on the robot
   (expression, look at someone, start following).

## Open questions for the owner

- `gpt-live-1` as recommended, or `gpt-realtime-2.1`?
- Voice and persona.
- Keep text transcripts in the logs, or nothing at all?
- Is a 3-minute idle stop right?
