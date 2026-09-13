# Local USB companion architecture

The StackChan is permanently connected to the Mac mini through USB-C. The
system therefore divides work by safety boundary and capability, not by a wish
to make the ESP32-S3 do expensive vision work.

| Place | Responsibilities | Explicit non-responsibilities |
| --- | --- | --- |
| StackChan | Camera capture and bounded transport, avatar/display, RGB state, input, a validated target-to-head controller, rate limits, servo bounds, and lost-target rest. | Face inference, identity recognition, cloud uploading, accepting raw motor commands from the mini. |
| Mac mini | Decode locally received frames, local face-presence/face-box inference using macOS Vision, choose at most one target, and return a confidence-qualified normalized position. | Directly writing servo angles, representing detection as eye contact, forwarding frames to a cloud service. |

The robot remains safe if the companion pauses, disconnects, or sends malformed
data: a target command is ignored unless it is syntactically valid, fresh,
strictly newer than the previous sequence number, within normalized bounds,
and at least the on-device confidence threshold. After 900 ms without a valid
target, the robot returns to its calibrated rest position. Motor control stays
disabled until physical calibration is complete.

## Initial USB protocol

The camera transport will be a bounded binary JPEG-frame protocol from the
robot to the mini. Each packet is `SBFR` (four ASCII bytes), version `1` (one
byte), a little-endian frame sequence (`uint32`), a little-endian JPEG length
(`uint32`), then that JPEG. The Mini rejects packets above 300,000 bytes and
resynchronizes after malformed input. It will be strictly USB-local; it has no
Wi-Fi setup, broker, cloud endpoint, or stored credential. The mini replies
over the same serial device with one ASCII line:

```text
T,<frame-sequence>,<normalized-x>,<normalized-y>,<confidence>\n
```

`x` and `y` must be in `[-1, 1]`, where `x=-1` is the left side of the camera
image and `y=-1` is the top. `confidence` must be in `[0, 1]`. The sketch parses
this response but receives no motor-angle protocol at all.

The mini may separately select a display-only emotion using a strict allowlist:

```text
E,normal|angry|glee|happy|sad|worried|focused|annoyed|surprised|skeptic|frustrated|unimpressed|sleepy|suspicious|squint|furious|scared|awe\n
```

This changes only the on-device eye expression; it cannot move the head, arm
the servos, or alter safety limits. Idle remains `normal` with slow local drift
and a blink about every 20–30 seconds.

The mini must emit a response only for an actual detected face. It may use face
rectangle position to suggest *apparent orientation/attention*, but neither a
face rectangle nor face landmarks establish eye contact. The display language
therefore says `person detected`, never `eye contact`.

`companion/stanbot-vision.swift` is a buildable macOS Vision implementation of
the Mini side. It accepts the packet format above, selects at most one largest
confidence-qualified face, and sends only `T` commands. It does not recognize
people, retain frames, use the network, or control motors. The firmware packet
producer is intentionally not enabled until low-rate JPEG output is validated
on hardware.

## Why this is the first choice

At QVGA the StackChan can concentrate on capture and responsive animation while
the mini runs a mature local model and can adapt policies without putting model
memory, power draw, or CPU contention on the robot. ESP-WHO remains useful as
an on-device fallback experiment, but it is not the primary path while USB is
always available.
