# USB recovery and factory restoration

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
