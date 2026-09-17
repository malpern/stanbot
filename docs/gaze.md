# Is the person looking at the robot?

Research on 2026-09-16, not yet tested on this robot. The question per frame is
whether a person is *facing* the robot, with an honest confidence. It is never
eye contact unless a calibrated score on a large, sharp face strongly supports
it (see the project brief).

## The constraint that decides everything

The robot sends 320x240 or 640x480 JPEG at 3-10 fps. A face at 0.05-0.25 of
the frame is 16-160 px wide, and the eye region is about a quarter of that:
often a few pixels of iris. Every gaze model below upsamples its face crop to
224 px, which invents no detail. Even the best published models are off by
about 10 degrees on sharp video, so at 0.5-3 m they can separate "toward the
robot" from "away", not "at its eyes" from "at its body". The camera is a few
centimetres from the drawn eyes, about 3 degrees at 0.5 m, well inside that
error.

## Plan

1. **Head-orientation gate (done, logging only).** Vision's face rectangle
   request (revision 3) reports yaw, pitch and roll. `Facing.swift` classifies
   each face: `toward` (|yaw| <= 35 and |pitch| <= 30 degrees), `away`, or
   `unknown` when the face is under 48 px wide or has no pose. Unknown is never
   reported as away. Nothing in the UI or on the robot uses it; session logs
   carry yaw, pitch and the class per detection, and `facing` for the face a
   target was sent for. All thresholds are guesses to be fitted.
2. **Gaze model behind the gate.** A face-crop gaze model converted to Core ML.
   Models trained on ETH-XGaze (PureGaze, GazeTR) led a 2026 zero-shot
   human-robot benchmark (Gaze4HRI, about 10-11 degrees) but are CC BY-NC, so
   their weights must not be committed to this public repo. L2CS-Net is MIT and
   the simplest to try first, but scored about 19 degrees there. Convert,
   measure latency on Apple Silicon, and compare on our own clips.
3. **Calibrate on the robot's camera.** Record a few hundred labelled clips
   (people, distances, lighting). Fit a confidence from gaze angle, face size
   and Vision's capture quality, per face-size band. Smooth over 3-5 frames,
   require several frames before saying yes, and answer unknown rather than no
   when quality is low.

## First conversion, 2026-09-16

The official L2CS-Net weights can no longer be downloaded: the README's Google
Drive folder returns 404 (L2CS-Net issue #47). Used instead: the MIT-licensed
retraining of the same method on the same Gaze360 data at
[yakhyo/gaze-estimation](https://github.com/yakhyo/gaze-estimation), whose
README reports Gaze360 mean absolute error of 11.34 degrees (ResNet-50) and
12.58 degrees (MobileOne-S0). Weights stay out of this repo; download them from
that repo's `weights` release.

`tools/gaze/convert_gaze_model.py` converts a checkpoint to Core ML with the
preprocessing and bin decoding built in: input a 448x448 RGB face crop, output
`yaw_degrees` and `pitch_degrees`. It loads checkpoints with
`weights_only=True`. `tools/gaze/GazeProbe.swift` runs Vision face detection
and the model on still images and prints one JSON line per face.

Measured on this Mac (torch 2.14, coremltools 9.0; torch newer than
coremltools has tested, no problems seen):

| Model | Core ML vs PyTorch, 5 random inputs | Core ML predict, CPU only | Core ML predict, all units | Per face through Vision (median, 62 faces) |
| --- | --- | --- | --- | --- |
| ResNet-50 (96 MB) | max 0.05 deg | 11.0 ms | 3.7 ms | 7.5 ms |
| MobileOne-S0 (5 MB) | max 0.30 deg | 3.7 ms | 0.9 ms | 1.6 ms |

Latency is not a constraint at 3-10 fps, even with several faces.

A first look on real faces: 13 frames at 640 px from that repo's sample video
(a group walking toward the camera; 62 faces, 32-79 px wide, which is our
range). There is no ground truth, so this is not accuracy. It shows two things:

- **Sign convention:** gaze yaw is the opposite sign to Vision's head yaw.
  Correlation of head yaw with *negated* gaze yaw: 0.86 (ResNet-50) and 0.89
  (MobileOne) for faces under 48 px, 0.85 and 0.79 for 48-80 px. Negate the
  model's yaw before comparing it with Vision's.
- **Small faces:** the median difference between head and gaze yaw is 24
  degrees for ResNet-50 on faces under 48 px against 12.5 at 48-80 px. Some of
  that is real (eyes need not point where the head does), but single readings
  such as gaze -65 with head +10 on a 33 px face look like noise. MobileOne
  was steadier on the smallest faces here (15 degrees), on too few frames to
  prefer it.

Next: record labelled clips from the robot's own camera (looking at the robot,
looking away, at several distances) and run the probe on them; that is what
decides whether the gaze model adds anything over head pose, and at what face
size.

## Considered and not first choice

- **Eye-Contact-CNN** (Chong et al., Nature Communications 2020) answers "looking
  at the camera?" directly and matched human coders, but was trained only on
  toddlers filmed at 1080p, and its licence forbids redistribution. Useful only
  as a comparison score.
- **ARKit `lookAtPoint`**: iPhone/iPad front camera only; not on macOS, not for
  an external camera.
- **Gaze-LLE**: estimates where in a scene someone looks, from a third-person
  view; the wrong question, and a heavy model.
- **UniGaze, OpenFace 3.0**: heavy or noncommercial; UniGaze may be useful
  offline for labelling.
- **MediaPipe iris**: iris points are guesses at these face sizes, and no
  official macOS Swift route was confirmed.

Unverified from the research: Gaze4HRI's figures (arXiv 2605.04770), whether
PureGaze/GazeTR weights convert cleanly to Core ML, latency of any of them on
Apple Silicon, and whether macOS 26/27 added a gaze API (none documented).

Sources: [eye-contact-cnn](https://github.com/rehg-lab/eye-contact-cnn),
[paper](https://pmc.ncbi.nlm.nih.gov/articles/PMC7736573/);
[L2CS-Net](https://github.com/Ahmednull/L2CS-Net);
[UniGaze](https://github.com/ut-vision/UniGaze);
[Gaze-LLE](https://github.com/fkryan/gazelle);
[Gaze4HRI](https://arxiv.org/html/2605.04770);
[PureGaze](https://github.com/yihuacheng/PureGaze);
[ETH-XGaze](https://github.com/xucong-zhang/ETH-XGaze);
[OpenFace 3.0](https://github.com/CMU-MultiComp-Lab/OpenFace-3.0);
[MediaPipe Face Landmarker](https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker);
[Vision FaceObservation](https://developer.apple.com/documentation/vision/faceobservation);
[ARFaceAnchor.lookAtPoint](https://developer.apple.com/documentation/arkit/arfaceanchor/lookatpoint).
