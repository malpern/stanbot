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

## Several people, 2026-09-16 (host-tested, not yet seen with real people)

The rules above have moved on (the match gate, clipping at the frame edge, and
missed-frame tolerance are described in `FaceSelection.swift` and
[head following](head-following.md)). Three rules now help when more than one
person is in view:

- **Where it was heading.** The selection keeps a smoothed velocity from the
  unsmoothed centres of its matches. Candidates inside the gate are ranked by
  distance from the predicted position, not only from the last one. Two people
  crossing are told apart by direction: at the crossing frame the stranger may
  be nearer, but the selected face is where it was going.
  (`testCrossingFacesKeepTheOneThatWasMovingThatWay`)
- **Size.** A candidate whose width differs a lot from the selection's costs
  0.3 x the fractional change, so a much smaller face (someone further back)
  that happens to be nearer is not taken for the selected person.
  (`testMuchSmallerNearbyFaceIsNotTheSelectedPerson`)
- **Returning person.** When a confirmed face is lost, its position is
  remembered for 3 s. A face back near it is preferred over anyone larger,
  though it still needs three matching frames. After 3 s the usual rule
  (largest, then most central) applies.
  (`testReturningPersonIsPreferredOverALargerStranger`)

The ambiguity rule is unchanged in spirit: a match must score clearly better
than the next (at most half its score, less 0.02), otherwise the state is
uncertain. Two equal faces either side of a still selection stay ambiguous.
The first two tests fail against the previous selector.
