# USB recovery and factory restoration

Transport facts that bound everything here — which port carries data, how fast
the link really is, and what the partition table allows — live in
[transport.md](transport.md). The short version: all USB data goes through the
**head** port on this unit, and the flashed partition table already supports OTA
(otadata plus two 3 MB app slots), so flashing over Wi-Fi needs no repartitioning.

## The screen came up as bands, and only a power cycle cleared it, 2026-09-17

The panel showed two bright cyan bars instead of a face. It survived
`C,REBOOT`, it survived flashing the firmware that caused it back off the
robot, and it was there through the boot splash -- which is drawn before any of
the suspect code runs. On that evidence I said it looked like a failing display
ribbon and sent the owner to wiggle the connector. Wrong. **A battery power
cycle fixed it completely.**

**`esp_restart()` does not reset the LCD's own controller.** The ESP32 restarts,
the driver re-initialises its side, and the panel keeps whatever internal state
it was left in. So a display corrupted by an aborted SPI transfer stays
corrupted across a software reboot AND across a reflash, which makes it look
like hardware, or like a fix that did not work.

**What aborted the transfer:** pushing the eye sprite from inside
`runFollowSession()`, contending with the camera stream and servo I/O (see
"drawing the face from inside a session" in head-following.md). That code is
reverted. If it is ever attempted again, know that a mistake there can outlive
the mistake.

**If the screen looks wrong:** power cycle before diagnosing anything. Hold the
robot's button; its battery means pulling USB is not enough. Only if the bands
survive a true power cycle is it worth suspecting the panel or its cable.

## Secure OTA installed and verified, 2026-09-16

All over Wi-Fi with `firmware/ota.py`, run from the mini through
`ssh malpern@openclaw.local`; USB on the side port was used only for the
passphrase and for observation.

1. `provision_wifi.py --ota-password` stored the passphrase over USB; the three
   Wi-Fi profiles were left intact.
2. 69cee81 to 63d5add with `--allow-unauthenticated`, the last upload the robot
   accepted without a passphrase (24.7 s, verified by `V`).
3. A wrong passphrase was refused at authentication after 2.4 s, before any
   image data was sent; `V` still reported 63d5add.
4. 63d5add to 87d44b0 with the real passphrase: authenticated
   (PBKDF2-HMAC-SHA256), 26.3 s, verified by `V`.
5. Over Wi-Fi, `W,O,...`, `W,?`, `C,REBOOT`, `C,FOLLOW` and `Q` each drew
   `SBNR {"refused":"usb_only"}` on both links, with no side effect on USB and
   no reboot; `V` still answered on Wi-Fi and USB.
6. With the passphrase cleared over USB and a reboot, the robot printed
   `SBWF {"ota":"disabled_no_passphrase"}` and did not answer an update
   invitation. Restored over USB and rebooted, it answered with an `AUTH`
   challenge again.

The robot ends on 87d44b0 with the passphrase stored. Rollback over USB at
0x10000 as before; note OTA alternates app slots, so after an OTA the running
image may be in the second slot.

## Version command installed, 2026-09-16

One application-only write at 0x10000 on the known device (head USB, MAC
`68:EE:8F:D8:4F:04` reconfirmed), hash-verified, no erase, no
partition/bootloader/NVS change. Image built by `firmware/build.sh` from commit
79da869 with a clean tree: 1,416,784 bytes, SHA-256
`8c2e7bebc6179b1cdcaf431a90fee79ff573a965879aec638b4be0f498d3f679`.
`--after hard-reset` brought the application up without a physical RST this
time, and `V` answered `commit 79da869729e6, dirty false,
follow_limits_measured false` both with the stream off and while streaming
(23 frames, zero dropped bytes through `sbstream.Demuxer`).

No app-partition backup was taken: the `read-flash` attempt failed with "No
more data to read from the serial port" and the write went ahead anyway. The
replaced image was the committed `camera_stream` at 3aaa2f9 (confirmed that
morning by its `C,FOLLOW` refusal format), so rebuilding that commit is the
rollback. From now on, `V` identifies the image before any flash.

## Yaw sweep diagnostic installed, 2026-09-15

Two application-only writes at 0x10000 on the known device (head USB), both
hash-verified, no full erase, no partition/bootloader/NVS change: the sweep
build (613,691 bytes) and its timing fix (613,719 bytes, SHA-256
daf2a1db1d6ef6ffdb004d74536152725277f5fb2f346eaf0057d97ea5019ecf). Each was left in the bootloader and
the user pressed RST. The serial port vanished twice this session after
resets; the cause was a Parallels VM capturing the USB device on
re-enumeration, not the connector (user diagnosed and fixed it). If
`/dev/cu.usbmodem*` is absent while the eyes are up, check VM USB capture
before touching the cable. The base USB port still does not enumerate on this
unit; the official docs say it should carry data, so that is a hardware fault
in this robot (internal seven-wire base-to-head cable suspected), not a design
limit. Factory state remains recoverable from the 2026-09-14 full backups.

## Settling diagnostic installed, 2026-09-14

With user present and side USB confirmed, reverified device MAC
`68:EE:8F:D8:4F:04`. Saved current full 16 MB factory state privately as
`pre-settling-test-full-flash.bin` in the recovery directory below (mode 0600).
ROM verify-flash matched its complete digest; SHA-256:
`fd94675f5cd0550f1320cc5ebd549049a520afa81dcfd8522c80851c34ac1d37`.
This backup may contain credentials: never commit or upload it.

Installed the 605,387-byte-program settling diagnostic using separate bootloader,
partition, OTA-selection, and application writes at 0, 0x8000, 0xe000, 0x10000.
No full-chip erase; every written segment passed hash verification. Current
factory state remains recoverable from the full backup. Left in bootloader with
no automatic/watchdog reset; physical brief RST and boot confirmation pending.
No servo-power test or movement/calibration command was sent in this installation.

## Return to StackChan factory image for RGB test, 2026-09-14

After the voltage and USB comparisons, user authorized restoring the saved
StackChan-UserDemo V1.5.1 for its built-in RGB test. Reconfirmed known device
identity on head USB and image SHA-256. Full erase and 12,783,792-byte write at
address 0 succeeded with written-data hash verification. Left in bootloader,
without automatic or watchdog reset. User should briefly press RST, choose
Skip at Welcome (avoid onboarding servo test), then navigate to Setup's RGB
test. RGB behavior and subsequent factory startup are pending observation.

## Power diagnostic installation, 2026-09-14

User confirmed StackChan-UserDemo V1.5.1 booted to Welcome and then the
AI.AGENT menu after Skip. Rear USB remained absent; moving the same cable back
to head USB restored the known serial device under the same official firmware.
Factory restoration is therefore now boot-tested, not merely flash-verified.

User photos show the rear red LED can also illuminate with side USB connected
and rear USB empty; it is not an exclusive rear-input indicator. A reported fix
in https://github.com/m5stack/StackChan/issues/78 identifies the central black
seven-wire cable (confirmed visually against the report image), NOT the silver
ribbon to its right. After USB removal and shutdown, user gently pressed the
black cable with a finger. Rear insertion then turned on the screen, but rear
USB enumeration remained absent, including after a physical restart. Neither
charging nor the precise failed connection is established.

With authorization, downloaded M5Stack CoreS3 UserDemo v0.12 from the M5Burner
CDN using catalogue file `814dba58deaf2918cc19b8088e3f602f.bin`. Saved alongside
the recovery copies as `CoreS3-UserDemo-v0.12.bin`, SHA-256
`b85af8bd116897ee71e00b5111b8b5643754f18990fcf322bd15638f98a6c5ea`.
Image header identifies ESP32-S3, DIO/80 MHz and an 8 MB layout (physical device
has 16 MB). Bootloader checksum/hash valid. After user moved to side USB,
reconfirmed serial identity; full erase and 7,138,816-byte write at address 0
succeeded with written-data hash verification. Left in bootloader without an
automatic reset. Diagnostic boot and voltage readings remain pending.

The Power page has interactive USB/BUS direction controls: do NOT toggle them
for the side/rear voltage comparison. Public source also conditions battery
voltage display on charge state, so a displayed 0 V alone must not be treated
as proof of a dead battery. Source: m5stack/CoreS3-UserDemo,
`src/pages/AppPower/AppPower.cpp` and `AppPowerModel.cpp`; exact correspondence
of public source to downloaded v0.12 has not been established.

## Controlled factory comparison, 2026-09-14

Rear USB did not enumerate on the Mini in either plug orientation. The user
confirmed the rear red LED follows cable connection, while eyes remain on even
when unplugged (battery operation). Returning the same cable to the head port
restored USB serial `68:EE:8F:D8:4F:04` at `/dev/cu.usbmodem31201`.
These observations do not establish rear-to-head power delivery or charging.

User authorized a factory-firmware comparison and confirmed head clearance and
cable slack. The companion was stopped before serial operations. M5Burner's
downloaded catalogue identifies `746f9662f48ac465cccf49bcad941414.bin` as
M5Stack **StackChan-UserDemo V1.5.1**, published 2026-07-31. This is not proven
to be the exact version originally shipped on this particular robot.

Recovery copies are outside Git at
`/Users/malpern/Library/Application Support/stanbot/recovery/2026-09-14/`:

- `stanbot-43c391c-merged.bin`: saved compiled custom image, SHA-256
  `defa56ffcc3442f885c57c6a325ab5e96c28e29c1ccc23d85b5410005576de88`.
- `StackChan-UserDemo-V1.5.1.bin`: official downloaded image, SHA-256
  `411578a2ebca2cfe3541fdc32aeddbc4703cf912a5daa7e1253f69306d6e1d87`.
- `pre-factory-rom-full-flash.bin`: complete 16,777,216-byte device backup,
  mode 0600, SHA-256
  `861952df0d2959a4493b24d5ed83b36c25d75497b7f6c88111c0c5b303fe21aa`.
  Treat this as sensitive: it may contain previous settings/credentials.
  Never commit or upload it. ROM `verify-flash` matched the complete digest.

The initial stub-based full read failed partway with a serial read error and
produced no backup file. The subsequent `--no-stub` full read and verification
succeeded. No flash write preceded that verified backup. Factory installation
uses address 0, full erase, and `--after no-reset`; physical startup and rear
port comparison are separate validation steps, not implied by flash success.

Installation result: the ROM-only attempt refused `erase_flash` as unsupported,
before erasing. Retried with the standard flasher stub: full erase succeeded,
12,783,792 padded bytes were written at address 0, and the written-data hash
verified. The device was left in the bootloader (`--after no-reset`). No watchdog
reset was used. Physical factory startup, rear-port enumeration, charging, and
servo behavior remain pending user observation. The companion remains stopped.

## Observed USB recovery, 2026-09-14

The head/screen USB-C port enumerated the known robot after the user held RST
during connection, then released it after the adjacent LED turned green.
Flashing succeeded. The normal RTS reset afterwards left the chip in its ROM
loader (`waiting for download`), so USB enumeration alone did not mean the
application was running. An esptool `--after watchdog-reset read-mac` operation
exited that state without changing flash. Confirm application output after
flashing, not just the presence of the USB port.

Caution: a later watchdog reset produced boot-time partition-table read errors
even though an independent flash verification matched the table/application.
The cause is unresolved. Do not treat watchdog reset as a reliable substitute
for a normal physical power cycle on this board. The last check left the robot
in its loader awaiting that physical cycle.

This is a verified custom-firmware recovery path, not a tested restoration of
the factory image. The historical preparation notes below have not established
a physical factory-restoration test.

## Original preparation notes

Factory recovery has been verified from M5Stack's StackChan documentation:

1. Use M5Burner and search for **StackChan**.
2. Enable **Only Official**, then download the latest StackChan image in the
   application. This keeps the recovery image selected by M5Stack rather than
   committing a binary of uncertain provenance to this repository.
3. Connect through the base USB-C port when possible; M5Stack recommends it to
   reduce the risk of a cable being struck by head movement.
4. In M5Burner choose **Burn**, select the verified serial port, then start.
5. If the port is absent, hold the bottom RST button for 3 seconds. Release when
   its adjacent indicator is green; the indicator going off confirms download
   mode.

On the mini, the connected device currently appears as `/dev/cu.usbmodem31201`
and as Espressif USB JTAG/serial device serial `68:EE:8F:D8:4F:04`. Reconfirm
this by unplug/replug before selecting it in any flashing UI; never select a
port by name alone.

M5Stack's current macOS M5Burner download is
`https://m5burner-cdn.m5stack.com/app/M5Burner-v3-mac-x64.dmg`. The mini
downloaded and inspected this official 94.2 MB disk image on 2026-09-13:

```text
SHA-256 6d9680a6d36ea572faef07f173c4343f0c3466227a8ae9429c8ed83cecdcd734
```

The contained `M5Burner.app` is unsigned, so it was deliberately not installed
or launched. Its StackChan factory image also remains un-downloaded. Installing
or bypassing Gatekeeper is a user-facing choice; no robot state has changed.
