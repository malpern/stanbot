# Firmware version

The robot reports what it is running in reply to `V`:

```
SBVR {"sketch":"camera_stream","commit":"3aaa2f989b4e","dirty":false,"built":"2026-09-16T18:20:00Z","protocol":1,"follow_limits_measured":false,"follow_pitch":true,"follow_yaw_range":288,"uptime_ms":6231}
```

## Why it exists

On 2026-09-16 the only way to tell which build was flashed was to send
`C,FOLLOW` and recognise the shape of its refusal. That worked once, by luck:
the newest commit happened to change what a refusal prints. Nothing tied the
image on the robot to a commit, flashing is manual, and the build folder held
exports older than the source.

The build that matters most is also the one that looked identical from the
outside. The 2026-09-15 calibration session flashed a throwaway build with
`kFollowLimits.measured = true`, the setting that decides whether the head may
move. `follow_limits_measured` and `dirty` are there so that build can never be
mistaken for the committed one again.

## Fields

| Field | Meaning |
| --- | --- |
| `sketch` | Always `camera_stream` for this firmware. |
| `commit` | 12-character git commit the image was built from, or `unknown` if not built with `firmware/build.sh`. |
| `dirty` | `true` if anything under `firmware/` differed from that commit, submodules and untracked files included. `null` when unknown. |
| `built` | UTC build time from the script, or the compiler's date and time otherwise. |
| `protocol` | `kProtocolVersion`. Bump it when a command, a reply line, or the SBFR packet format changes in a way the app must know about, and bump `FirmwareInfo.expectedProtocol` in the app with it. |
| `follow_limits_measured` | `stanbot::kFollowLimits.measured`. `true` means head following can enable motor power. |
| `follow_pitch` | A `STANBOT_FOLLOW_PITCH=1` build: following tilts the head as well as turning it. Absent on older firmware, which means yaw only. |
| `follow_yaw_range` | Yaw travel either side of centre, in raw steps. Absent on older firmware. |
| `uptime_ms` | `millis()` when the line was sent. It tells a robot that has just rebooted from one that was up all along and the app merely reconnected to: the app gives the first kind a look around and the second nothing (`AutoFollow.justBootedUptime`, 30 s). An uptime that has gone backwards since the last report is a new boot. Absent on older firmware, which claims nothing. |

## How the commit gets in

The firmware cannot discover its own commit. `firmware/build.sh` writes
`build_info.h` next to the sketch, compiles, and deletes the header whether or
not the compile succeeded, so a later bare `arduino-cli compile` falls back to
`unknown` instead of inheriting a stale identity. The header is gitignored.

The script also deletes old exports before compiling and writes
`build_info.json` beside the binaries with the commit, dirty flag and SHA-256,
so the file you flash can be matched to what the robot later reports.

**Commit before building anything you intend to flash.** A dirty build reports
`dirty:true` for as long as it stays on the robot.

## In the app

The companion sends `V` on every connect, before starting the stream, and
retries twice at two-second intervals. The Firmware card shows the sketch and
commit, and turns orange for any of: limits marked measured, a protocol
mismatch, an unknown commit, uncommitted changes, or no reply at all (firmware
older than this command).

The reply is safe to read while frames flow: the firmware writes it from the
same task that writes frames, and the app only looks for text lines in bytes
outside a packet.
