# Local face detection plan

The first sketch defines a `FaceObservation` boundary but returns no synthetic
observations. A camera being connected or a face-shaped region being detected
must never be represented as confirmed eye contact.

The on-device implementation target is ESP-WHO, pinned for evaluation at
`1abda05e1c0782237fcb9e8d33a2fa7e105f06b2`. Its `HumanFaceDetect` model returns
bounding boxes and scores; the selected highest-confidence face will become a
`FaceObservation` only after a conservative score threshold and time-stamp
check. The official firmware's StackChan board configuration supplies the
GC0308 DVP pins: D0..D7 `39,40,41,42,15,16,48,47`, VSYNC `46`, HREF `38`, PCLK
`45`, with the sensor's external clock and existing I2C bus.

ESP-WHO supports ESP-IDF 5.5, and its face detector runs asynchronously from
camera capture. The next firmware iteration will be an ESP-IDF project using
that pipeline rather than attempting to force ESP-WHO through Arduino. It will
be build-tested before it is allowed to command the motors.

The head controller only accepts observations that are present, recent and at
least `0.70` confidence. It ignores a target after 900 ms, then returns to the
calibrated rest position at a limited speed. These are conservative starting
values, not hardware validation.
