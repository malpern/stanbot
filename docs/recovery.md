# USB recovery and factory restoration

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
