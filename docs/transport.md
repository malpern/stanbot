# Transport: what the link can and cannot do

Measured facts about getting data between the robot and the Mac, and the
reasoning they settle. Most of this was re-derived more than once during
bring-up; it is written down so it is not re-derived again.

## The two USB-C ports

The official documentation is explicit that **both** ports carry data, and it
recommends the **base** port for programming, so a turning head cannot drag the
cable it is attached to.

**On this particular robot the base port does not enumerate.** Verified in both
plug orientations, with the same cable that works in the head port, on 2026-09-14
and again on 2026-09-15. Power does reach the base: the red LED follows the
cable and rear insertion has lit the screen. So this is a fault in this unit,
not a design limit, and the likely path is the internal seven-wire base-to-head
cable. [Issue 78](https://github.com/m5stack/StackChan/issues/78) reports the
same symptom set on another unit, with charging through the base also failing.

**Update, 2026-09-17:** at 11:47 that day the base port began enumerating
(`/dev/cu.usbmodem31201`, the robot's MAC), with the cable still in the back,
and a full flash backup and the USB bench tools then ran through it. Nothing
explains the change (the head had been steered into its hard stop and lowered
by hand that morning); treat it as luck, and the head port as the recovery path.

Consequences while it stays broken:

- All USB **data** goes through the head port, including every flash.
- The head port is the recovery path if anything else fails.
- Base-port power is still useful, because it is the stationary connector.

## Two ways USB goes silent while the robot is perfectly well

Both were diagnosed as a dead or broken robot before being understood, and
neither announces itself: the symptom of each is that commands get no reply.

**1. DTR must be asserted, or the robot never receives a byte.** The ESP32-S3's
USB CDC only delivers host writes once DTR is raised, and `os.open` does not
raise it. A plain open therefore sends commands into nothing. Verified
2026-09-18: with DTR raised `V` answered instantly; without it, silence, on the
same cable and firmware. On macOS:

```python
fcntl.ioctl(fd, 0x8004746C, struct.pack("I", 0x002 | 0x004))   # TIOCMBIS, DTR|RTS
```

`tools/usb_port.py` does this for every tool that opens the port. Anything new
that talks to the robot over USB should use it rather than opening the device
itself. `tools/test_usb_port.py` pins the ioctl, because the failure it prevents
is invisible from the code.

**2. A second reader takes the replies.** `/dev/cu.*` may be opened by several
processes at once and they do not share: each byte goes to whichever read wins.
So while Stanbot holds the port, a tool can send a good command, the robot can
answer correctly, and the tool sees nothing. This is what produced the "no SBST"
failures of 2026-09-17, and a `C,REBOOT` on 2026-09-18 that appeared to vanish —
seven copies sent, `uptime_ms` still climbing.

It cannot be distinguished from a dead robot by looking at the silence, so the
tools ask the operating system instead: `usb_port.contention_note()` runs `lsof`
and names the other holder. `check_sleep_wake.py` refuses outright; `check_mouth.py`
cannot, because the robot only accepts mouth packets from its current Wi-Fi
viewer and so Stanbot must be running — it reports which process is taking the
replies and suggests putting Stanbot on Wi-Fi. **Quitting Stanbot is not the
general fix; anything holding the port does this**, including a serial monitor
or another check.

## Which task answers, and when

Three tasks share the robot, and **which one is running decides what can be
answered**. This is not a detail: a screenshot asked for during a follow session
went unanswered for the whole session -- the state the robot is in most of the
time -- because both tasks that normally handle it were stopped.

| Task | Normally | During a follow session |
| --- | --- | --- |
| **loop** | draws the face, `pollCommands` (USB input) | inside `runFollowSession`: draws nothing, parses no USB |
| **camera** | camera frames, `pollNetworkCommands`, owns the viewer socket | **blocked in `captureBuffer()`** -- the session task has the camera |
| **sessionCapture** | not running | frames, `pollNetworkCommands`, owns the viewer |

So anything that must work during a session belongs on `sessionCaptureTask`,
and anything writing to the viewer must be on whichever task owns it -- never
both. `serviceScreenshot()` is called from the camera task normally and from
the session task during a session, and is shared so the two cannot drift.

**The face is frozen for the length of a session** (which is why it does not
animate while the head moves), so copying the sprite from another task is safe
there. Outside a session the loop task takes the copy between a push and the
next draw, where the frame is whole by construction.

**Known limitation:** USB commands are parsed by `pollCommands` on the loop
task, so a command sent over USB during a session is not seen until the session
ends. Wi-Fi commands are parsed throughout.

## The app is the way to command the robot, not a second reader

Because two processes on one `/dev/cu.*` do not share, anything that wants to
command the robot from a shell should go **through the app**, which already
holds the transport: `tools/stanbot sleep`, `wake`, `reboot`, `follow`,
`unfollow`, `mouth`, `expression`, `screenshot`. The CLI writes
`~/Library/Logs/Stanbot/command.json` with a fresh id; the app carries it out
and writes `command-result.json` with the same id, so a previous answer is
never mistaken for this one. See `CommandFile.swift`.

It is exactly as privileged as the user's own shell and no more: anything that
can write that file can already open the robot's USB port, and the robot's own
authorization still applies to everything that moves the head. `off` is
deliberately not in the vocabulary -- only the robot's button undoes it.

## USB speed is the robot's limit, not the Mac's

The link negotiates to its slowest end, and the ESP32-S3's built-in serial
peripheral is **USB 1.1 full speed, 12 Mbit/s**, with no faster mode. Read off
the live bus on 2026-09-15:

| Device | Negotiated speed |
| --- | --- |
| StackChan | Full speed, 12 Mbit/s |
| The hub it is plugged into | High speed, 480 Mbit/s |
| A USB3 Gen2 hub on the same tree | 10 Gbit/s |

Measured payload throughput is 730–900 KB/s after framing overhead. **A
Thunderbolt port, a different cable, or a different hub cannot change this.**
Check `"Device Speed"` in `ioreg -p IOUSB -l` before blaming anything upstream.

## A polled reader loses data; this is not a bandwidth problem

The robot writes each frame as one burst. A 21.7 KB frame lands in about 24 ms.
A reader that polls every 50 ms can miss the whole burst, and the terminal input
buffer is smaller than a frame, so the kernel discards the tail before anyone
reads it. The decoder then resyncs and the frame is lost entirely.

This is why the companion app appeared to stop seeing faces after the encoder
quality went up: bigger frames, more loss. See camera-performance.md for the
measurements. The fix is to read from a dispatch source that drains as bytes
arrive. **Frame size then stops mattering, and the same code works on a socket.**

Any tool that drains the port continuously with large reads will not reproduce
this, which is exactly why the robot-side benchmarks looked perfect throughout.

## The three ceilings on image quality

Distinguishing these prevents chasing the wrong one.

| Ceiling | Set by | Can it be raised? |
| --- | --- | --- |
| 640×480 of detail | The GC0308 sensor, 0.3 MP | No. Hard cap wherever processing happens |
| Compression artifacts | The ESP32's software JPEG encoder | Yes, by not compressing |
| About 5.2 fps | The slowed pixel clock, and ~136 ms of work per frame | Faster clock gives 7.8 fps but tears (re-tested 2026-09-16, see camera-performance) |

Encode is the ESP32's own wall and it is large: VGA JPEG spends about 498 ms per
frame compressing, which is why VGA runs at 1.9 fps and falls to 1.6 at quality
90. At QVGA the rate is capped by capture instead, which is why bitrate there is
effectively free.

## Moving work to the Mac does not help; this was measured

Shipping raw pixels so the Mac does everything was benchmarked on 2026-09-14:

| Mode | Rate | Payload | Robot prep | USB write |
| --- | --- | --- | --- | --- |
| QVGA JPEG | 3.54 fps | 7.9 KB | 170 ms | 9 ms |
| QVGA raw | 3.50 fps | 153.6 KB | 41 ms | 210 ms |

Offloading the encode saved 129 ms of robot work and spent 201 ms more on the
wire, at 19 times the bytes. Scaled to VGA raw at 614 KB per frame, USB gives
about 1.2 fps, which is **worse** than the 1.9 fps VGA JPEG already manages.

## Where Wi-Fi does and does not help

Wi-Fi is genuinely faster than full-speed USB, but that is not the constraint
today. Remove the wire from the VGA measurement entirely and the rate goes from
1.92 to about 2.0 fps, because the 498 ms encode remains. At QVGA the wire is
9 ms out of 282 ms, and quality 90 uses 76 KB/s against 730–900 KB/s available,
roughly 8% utilised.

**Wi-Fi is transformative for exactly one configuration: uncompressed VGA.**
That removes the encode wall and the bandwidth wall at once, and is the only
path to artifact-free full-sensor images at close to the capture ceiling.

| Path | Rate | Quality |
| --- | --- | --- |
| VGA JPEG over USB | 1.9 fps | Heavily compressed, about 0.5 bits/pixel |
| VGA raw over USB | About 1.2 fps | Lossless |
| VGA raw over Wi-Fi | Not available: no raw VGA mode exists; raw QVGA over Wi-Fi measured slower than USB (below) | Lossless, full sensor |

Caveats: the ESP32-S3 is 2.4 GHz only, this house runs a crowded mesh, and
throughput there swings with interference. Treat any number as needing
measurement. Jitter will also matter more than throughput once the head is
following a face.

## Wi-Fi against USB, measured at home 2026-09-16

`companion/benchmark_transport.py`, 30 s per setting after a 2 s settle, video
over TCP to `stanbot.local` and then over USB, same firmware (79da869), robot on
`Alpern-Home-5G` at -39 dBm. Run from the mini through
`ssh malpern@openclaw.local`, because agent shells there cannot reach LAN
hosts directly.

| Setting | Link | fps | Lost | Interval p50 / p95 / max ms | Command reply p50 / max ms | Send time per frame ms |
| --- | --- | --- | --- | --- | --- | --- |
| QVGA JPEG q90, 200 ms | Wi-Fi | 3.43 | 0 | 278 / 444 / 473 | 121 / 430 | 59 |
| | USB | 3.49 | 0 | 354 / 391 / 396 | 171 / 361 | |
| QVGA JPEG q90, 100 ms | Wi-Fi | 3.43 | 0 | 277 / 453 / 490 | 160 / 374 | 58 |
| | USB | 3.50 | 0 | 342 / 390 / 398 | 163 / 386 | |
| VGA JPEG q90, 100 ms | Wi-Fi | 1.46 | 0 | 676 / 789 / 798 | 243 / 662 | 145 |
| | USB | 1.63 | 0 | 622 / 634 / 643 | 264 / 644 | |
| Raw QVGA, 100 ms | Wi-Fi | 2.46 | 0 | 434 / 458 / 488 | 206 / 429 | 359 |
| | USB | 3.26 | 0 | 289 / 435 / 458 | 174 / 290 | |

What this settles:

- **For the stream the app uses, Wi-Fi costs nothing measurable.** QVGA JPEG
  runs at the same rate with no lost frames. The rate is set by capture and
  the roughly 208 ms encode, exactly as the section above predicted, so
  neither link is the limit.
- **Wi-Fi is a little less steady.** The worst gap between frames was about
  470-490 ms against about 400 ms on USB. Command replies look alike on both,
  because they wait behind a frame in progress. Head following will feel
  that, but the gap is small beside the frame interval itself.
- **The prediction that Wi-Fi would win for uncompressed video was wrong.**
  Raw QVGA fell from 3.26 fps on USB to 2.46 on Wi-Fi. Sending one 150 KB
  frame took 359 ms, about 420 KB/s. That is far below what the radio link
  should carry at -39 dBm, so the ceiling is most likely the ESP32's TCP
  send path (lwIP buffers and window), not the air. Unmeasured: tuning those
  buffers might change this. There is also no raw VGA mode to test.
- **Signal was strong.** Everything here is a best case for this house. The
  robot across a room, or a busier evening on 2.4 GHz, is untested.

### App fixes that this test needed

The app could connect over Wi-Fi but never had a working video path:

- `startCamera()` required the USB descriptor, so over Wi-Fi it reported the
  camera unavailable and never sent `S`.
- A Wi-Fi link that dropped was never retried, because `tick()` treated the
  chosen transport as if it were up.
- An unplugged USB device was retried forever instead of falling back to
  Wi-Fi.

All three are fixed and covered by `NetworkTransportTests`, which run a fake
robot on loopback and fail against the old code. To use Wi-Fi with the cable
still attached, choose Wi-Fi only in Settings, or launch with
`open Stanbot.app --args -StanbotTransport wifi`. The default is now Wi-Fi with
USB fallback; see the README. Verified live: the app
connected over Wi-Fi, started the camera on its own, and the robot reported a
Wi-Fi client with 17 frames sent in 5 s and none to USB.

## OTA is already possible; the partition table supports it

Checked on 2026-09-15 by decoding the partition table actually flashed:

| Partition | Offset | Size |
| --- | --- | --- |
| nvs | 0x9000 | 20 KB |
| otadata | 0xe000 | 8 KB |
| app0 | 0x10000 | 3 MB |
| app1 | 0x310000 | 3 MB |
| ffat | 0x610000 | 9.9 MB |

Two application slots plus otadata, and the firmware is about 614 KB, so **no
repartitioning is needed to flash over Wi-Fi.** OTA writes to the inactive slot
and only switches otadata once the image verifies, so a failed transfer leaves
the running firmware untouched.

The residual risk is different: an image that flashes and verifies but then
fails to boot or fails to join Wi-Fi cannot be recovered over the air. The head
USB port is the fallback for that, and the 2026-09-14 full-flash backups are the
floor under it. The project brief's rule still holds — OTA only on top of a
working USB recovery path, which factory restore has now boot-tested.

## Credentials never live in this repo

Wi-Fi credentials belong in NVS on the device, provisioned over the wire, and in
sops on the Mac. `~/dotfiles/secrets.env` already carries other projects'
Wi-Fi credentials under a project prefix; follow that. Never commit an SSID
password, never print one to a log or a transcript, and never echo one back from
the firmware.

## Wi-Fi transport, as built 2026-09-15

Since 2026-09-17 the robot also listens on **UDP port 3334** for the speaking
mouth: 11-byte packets, accepted only from the connected viewer's address, that
change nothing but the drawn mouth. A separate port because the command channel
is only read between camera frames. See [voice](voice.md).

`C,SLEEP` and `C,WAKE` are allowed over Wi-Fi without the passphrase: they only
darken the screen and stop the stream, which `X` and `S` already do. `C,OFF`
powers the robot down completely and is authorized like `C,FOLLOW` and
`C,REBOOT`, because only the robot's own button undoes it.

Implemented so the cable can move to the base connector and carry power only.
Both transports speak the same SBFR packets and newline commands, so the
companion's decoder and every command are shared and either link works.

- **Credentials live in NVS**, never in this repository, pushed over USB by
  `companion/provision_wifi.py` which reads them from sops. The firmware never
  echoes a passphrase, not even in its status line.
- **Several profiles, tried in order.** Home is a pre-shared key; **Hacker Dojo
  is WPA2-Enterprise and needs a PEAP identity**, which is a difference in kind,
  not just in name. The profile order and PEAP setup mirror the KeyPath HID
  fixture, which already works there. A profile that does not associate within
  12 seconds rotates to the next, so one image works at both venues. Up to five
  profiles are stored (`kMaxProfiles`), which the provisioner enforces too.
- **`W,SCAN` reports what is actually broadcasting.** Use it before trusting an
  SSID from a note. It found that neither `Alpern-Home` nor `Alpern-Fiber`
  exists here: the eeros broadcast `Alpern-Home-5G` on 2.4 GHz channels 6 and
  11, so despite the name that is the network to join. A scan on 2026-09-15
  also settled `Saturday`: it had been provisioned as `SATURDAY` from a note
  and never associated, because SSIDs are case-sensitive. Copy the spelling
  from the scan, not from a note, before blaming the passphrase.
- **A scan stands the join rotation down first.** A join in flight owns the
  radio, and `scanNetworks()` then fails outright with `WIFI_SCAN_FAILED`
  (`{"scan":[],"count":-2}`). Because the rotation above restarts a join every
  12 seconds, a robot with profiles stored never had a free radio, so until
  2026-09-15 the scan a stuck robot most needed was the one it could never run:
  `W,SCAN` worked only on an unprovisioned device, which is the opposite of the
  advice above. `scanWifi()` now disconnects, waits for the radio to leave the
  connecting state, scans, and resumes the rotation at the same profile with a
  fresh 12-second window. A scan therefore costs a few seconds of joining, and
  a `W,SCAN` is followed by a `joining` line for the profile it resumed.
- **Modem sleep is disabled.** It is on by default and cost 78-110 ms of round
  trip on a -38 dBm link, which is invisible for a status poll and ruinous for
  video. The robot is mains powered, so the trade is free.
- **mDNS**: the robot answers to `stanbot.local` and advertises `_stanbot._tcp`.
  Nothing hardcodes an address.

### Two macOS gates that look like an unreachable robot

Both produce the same symptom, a connection that never completes, and neither
reports anything useful.

**The app must be properly code-signed.** `swift build` leaves a linker ad-hoc
signature whose identifier is the product name and which does not cover
`Info.plist`. macOS then cannot attribute the app for permissions: no prompt
appears, the app never appears under Privacy & Security, and
`NSLocalNetworkUsageDescription` is ignored. `build-app.sh` now signs the
assembled bundle with the Developer ID identity and verifies it. Prefer a real
identity over ad-hoc: an ad-hoc designated requirement is derived from the
binary, so every rebuild looks like a different app and the permission is asked
for again.

**`Info.plist` must declare the intent.** `NSLocalNetworkUsageDescription` and
`NSBonjourServices` (`_stanbot._tcp`) are both required.

**Agent shells on the mini cannot reach LAN peers at all.** This is the known
Local Network restriction: the gateway answers, every peer fails, and ARP still
resolves. Verify from the linux box instead, or over Tailscale. It does not
affect the robot or the app, only what can be checked from a shell here.

### A third cause, which is not macOS at all

An access point that isolates its clients produces exactly the fingerprint
above — the gateway answers, every peer fails — and no permission granted on
the laptop will change it. Hacker Dojo does this. Measured there on 2026-09-15
from a Mac with Local Network allowed: the robot reported itself associated and
holding `10.43.10.43` over USB, while from the laptop on that same SSID it
dropped every ping and refused port 3333, and a sweep of the whole `/23` found
only the gateway and the laptop itself.

**The test that separates them** is whether anything *else* on the network
answers. A permission problem is per-app and specific to your traffic; other
hosts still populate the ARP table. Isolation is network-wide: nothing answers,
including devices that have nothing to do with this project, and every ARP
entry stays `(incomplete)`. Sweep the subnet before blaming the laptop.

**It isolates unicast, not multicast.** Calling it "client isolation" without
that qualifier overstates it, which the first version of this note did. An
mDNS browse left running through the same evening saw `stanbot` advertise
`_arduino._tcp` repeatedly, appearing and disappearing as the robot rebooted,
while unicast to its address stayed dead throughout. So discovery works and
the connection does not: the robot can be *seen* at the Dojo and still not be
*reached*, and finding it by Bonjour proves nothing about whether a socket
will open. `stanbot.local` failing to resolve there was a consequence of the
laptop never completing the unicast exchange behind the name, not of the
advertisement being blocked.

Ask the robot over USB what it thinks its address is before concluding anything
from the laptop's side. It reports `connected`, `ssid` and `ip` in its `W,?`
status, and at the Dojo it was on the network the whole time and simply
unreachable.

The app cannot tell these apart either: `describe(_:)` collapses `EPERM` and
`EHOSTUNREACH` into one "blocked; allow Stanbot under Local Network" message,
which names the wrong cause half the time. Worth splitting when it next gets
touched.

Where this leaves Wi-Fi at the Dojo: the video socket does not open, so USB is
the transport there. A phone hotspot puts both ends on a network we control
and sidesteps the isolation, which is what the `--phone` profile is for.

## OTA

### Tested over Wi-Fi, 2026-09-16

`firmware/ota.py` flashed commit 69cee81 (clean, 1,416,784 bytes) from the mini,
run through `ssh malpern@openclaw.local`, with the cable in the power-only base
port. The upload took 19.9 s, the robot answered `V` 6 s later, and it reported
`69cee81ecd61`, `dirty:false`, `follow_limits_measured:false`, replacing
79da869. OTA works end to end, and `V` is how each update is confirmed.

**Closed the same day.** That first upload was accepted without a passphrase,
and storing one would not have helped: every TCP line reached the same
`handleCommand()` as USB, so anyone who could reach port 3333 could set a new
OTA passphrase with `W,O`, rewrite Wi-Fi profiles, reboot, or run the
supervised motion commands. Commit 63d5add fixed both halves:

- **Wi-Fi viewers get an allowlist** (`firmware/camera_stream/network_policy.h`):
  `S`, `X`, `V`, `P`, `Z`, and the `E,` `T,` `R,` `M,` `J,` `G,` prefixes. Everything
  else, including every `W,` and `C,` command and `Q`, is USB-only and answered
  with `SBNR {"refused":"usb_only"}`. The refusal never echoes the line, since
  a refused `W,O` carries a passphrase. A command added later is USB-only until
  someone adds it to the allowlist on purpose.
- **No passphrase, no OTA.** `ArduinoOTA` starts only when a passphrase is
  stored in NVS; otherwise the robot prints
  `SBWF {"ota":"disabled_no_passphrase"}` and ignores update invitations.
- **The passphrase is set over USB only**, with
  `companion/provision_wifi.py <port> --ota-password`, which on its own leaves
  the Wi-Fi profiles alone. It takes effect at the next boot.
- **`firmware/ota.py` fails any upload the robot did not authenticate.**
  `--allow-unauthenticated` exists for the single migration upload from older
  firmware, which is how 63d5add was installed.

Security that remains out of scope: authentication protects starting an update,
not the image in transit. The firmware travels unencrypted and unsigned, so an
attacker able to intercept traffic on the same network during an update could
substitute one. Avoid updating on shared networks such as Hacker Dojo, or use a
phone hotspot. Signed images would close this; Espressif's secure boot does so
by burning eFuses permanently, which is a separate decision.

The original section follows.


`ArduinoOTA` is enabled once the network is up, with a passphrase from NVS
(`STANBOT_OTA_PASSWORD` in sops, generated locally and never displayed). It
matters most at Hacker Dojo, where an unauthenticated updater on the same
network could replace the firmware. The partition table already supports this;
see above.
