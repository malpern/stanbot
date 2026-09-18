# The Live spike

A command-line client for OpenAI's Live API, written to settle the facts
`docs/voice.md` listed as unverified before anything was built on them. Headless
on purpose: it speaks by feeding synthesized samples and listens by writing a
WAV, so it runs with nobody there and makes no sound.

```
swiftc -O live_spike.swift -o live_spike
./live_spike --dry-run                 # say/afconvert plumbing, no network, no spend
./live_spike --seconds 40 --voice vesper
./live_spike --seconds 40 --barge-in "Stop. Just say the word banana."
```

`voice-spend.json` is a ledger, not a good intention: every run adds to it and
the next refuses to start past the cap (the owner set $5 on 2026-09-17).
`live-spike-report.json` is what the run learned; `live-reply.wav` is what the
model said.

## What it settled, 2026-09-17

Four guesses in the plan were wrong, and the server rejected them one at a time
for nothing — an error arrives before a session starts, so a wrong shape costs
$0.00. **Start minimal and read `session.started` back**: the server echoes the
whole session object, which is a better schema than guessing a field at a time.

| | in the plan | actually |
| --- | --- | --- |
| voice field | `session.voice` | `session.audio.output.voice` (`session.voice` is rejected) |
| audio config | `audio.input`/`audio.output` formats | `audio.format = {"type":"audio/pcm","rate":24000}` |
| voice name | `cedar` | not a Live voice; default is `marin`, and `vesper` works |
| end of reply | watch your own playback | no event, confirmed (see below) |

Verified working: endpoint `wss://api.openai.com/v1/live/sessions`, bearer
header, `session.start` first, `session.input_audio.append` with base64 PCM,
`session.output_audio.delta` back. Mono signed 16-bit little-endian at 24 kHz
is right. A 3.5 s question drew a 6.2 s spoken answer, first audio 1.1-2.9 s
after connect.

Events seen, in first-appearance order: `session.started`,
`session.output_audio.delta`, `session.input_transcript.delta`,
`session.output_transcript.delta`, `session.usage.updated`.

- **Session limit: 2 hours.** `expires_at` in the session object was 7199 s
  ahead. The app's 3-minute idle stop and daily limit are far tighter, so this
  never binds -- but it is no longer unknown.
- **Usage comes from the server**: `session.usage.updated` carries
  `{"seconds": 11}`, so minutes-used can be reported rather than estimated.
- **Interruption: it works, and nothing announces it.** Talking over a reply
  cut it off mid-sentence -- the transcript reads `" I'm a tiny desk
  robot" + "banana"` where the full answer would have been "I'm a tiny desk
  robot built to give quick help" -- and the model obeyed the new instruction.
  But the events after the barge-in are only more `output_audio.delta`: there is
  no cancel, no cleared, no flush. **So the playout buffer IS the interruption
  mechanism.** Whatever is queued locally will be heard; keep it at about 200 ms
  and stale speech stays under a fifth of a second. This was the pass criterion
  the plan said Live could not be adopted without, and it passes on that
  condition.
