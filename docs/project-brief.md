# Project brief

## Product requirements

- Prefer local robot control and local camera processing over factory cloud services.
- Use a simple expressive face with blinking, a mouth, and a distinct attention acknowledgment.
- Distinguish face presence, apparent orientation, and uncertain attention; do not claim confirmed eye contact.
- Use calibrated servo limits, smooth motion, sensible update rates, and a safe lost-target/resting behavior.
- Structure firmware as small testable modules so audio, sensors, and scoped agent control can be added later.
- Aim for complete hardware coverage; reproducing factory cloud features is a separate scope.

## Reported setup — verify before relying on it

- Official M5Stack StackChan with factory firmware; factory AI Agent and Avatar modes previously used.
- Mac mini companion reachable through `ssh mini`; identity, OS, build tools, and USB state require verification.
- Robot not yet connected to the mini through USB-C.
- First custom flash requires a data-capable USB-C connection. Plan OTA only after working USB recovery.
- M5Burner factory restoration was identified in prior work; verify the exact image and procedure before flashing.

## Implementation direction

Evaluate official M5Stack firmware, BSP, and examples before writing drivers. Evaluate ESP-IDF/ESP-WHO or equivalent for on-device face detection. If attention estimation needs companion processing, transmit only necessary frames locally and return confidence-qualified attention state.

## Operating constraints

Never commit or log Wi-Fi passwords, broker tokens, or other credentials. A previously shared cloud broker endpoint was not direct motor/camera access and must not be reused. Do not identify the robot from an unverified LAN address. Ask the user to connect the hardware once the build and recovery workflow are ready. Clearly separate implemented, build-tested, and physically verified capabilities.
