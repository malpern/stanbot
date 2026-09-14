# Local face selection

The Mini runs Vision locally. A geometry-only selector chooses one face; it does
not recognize identity, determine attention, or confirm eye contact. No target
or motion commands are sent to the robot. Firmware and calm idle eyes are unchanged.

- Require confidence ≥ 0.7, valid normalized geometry, and three matching observations.
- Initially prefer the largest face, then horizontal proximity to image center.
- Preserve one selection ID and smooth its rectangle with a 0.65 update weight.
- Require bounding-box intersection-over-union ≥ 0.2 to retain the selection.
  Multiple matching candidates are ambiguous, not permission to pick one.
- On a missed/ambiguous detection, remove the rectangle immediately and show
  “Target uncertain.” Retain the selection internally for at most 0.9 seconds
  since last observation; then return to “No stable face detected.” A different
  face must subsequently pass fresh three-observation confirmation.
- Without fresh detections, hide a formerly selected box after 0.45 seconds.
- Publish each decoded image with its analysis result. Discard analysis from old
  connection generations and results older than 0.75 seconds.
- Stop, disconnect, and stream timeout reset selection. Reduced Motion disables
  rectangle interpolation; state labels convey meaning without relying on color.

These are starting thresholds, not calibrated probability or identity guarantees.
Crossing faces, fast movement, occlusion, and poor light may lose or misassociate
a target. This is why motion remains locked.

## Validation, 2026-09-14

Seven automated tests passed: five selector tests covering acquisition, smoothing,
stable IDs, loss/other-face suppression, brief reacquisition, confidence filtering,
ambiguity, expiry and reset; two existing pseudo-terminal disconnect tests.
Release app built and relaunched with local camera streaming. Real-person target
entry/exit and multiple-person behavior require physical validation.
