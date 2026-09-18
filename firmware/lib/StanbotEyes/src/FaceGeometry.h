#pragma once

// What the face IS, separately from how it is painted.
//
// Stanbot has two faces -- the robot's 320x240 panel and the Mac's -- and they
// are meant to be one character at two fidelities: the same state read the same
// way, drawn with whatever each machine can afford. That worked only as long as
// somebody kept two piles of numbers equal by hand, and it repeatedly did not:
// closed eyes were a sagging curve on the Mac and a 2 px bar on the robot; the
// frown sat 12 px off the bottom of the screen in BOTH, hand-copied and wrong
// twice over; being in trouble stopped the robot closing its eyes but not the
// Mac's.
//
// So the contract is here, in one struct, and it is deliberately SEMANTIC:
// where each thing is, how big, and what kind. It says nothing about glow,
// anti-aliasing, springs, or how many segments an arc is drawn in -- those are
// fidelity, they are supposed to differ, and a contract that mentioned them
// would report the difference as a fault every time.
//
//   State and shape may not differ. Fidelity may.
//
// `StanbotEyes::geometry()` computes this and `draw()` paints it, so the robot
// cannot draw something its geometry does not describe. The Mac's FaceGeometry
// .swift mirrors it, and companion/face-geometry.json holds the robot's answer
// for a set of named states so both sides can be checked against one file.
//
// Plain C++ with no Arduino dependency, so it compiles on the Mac too.

#include <cstdint>

namespace stanbot {

/// The three things an eye can be. Not a rendering detail: each reads as a
/// different state to anyone looking at the robot.
enum class EyeKind : uint8_t {
  Open = 0,     ///< the iris, with a pupil
  Closed = 1,   ///< a lid: the sagging curve, awake or asleep
  Crossed = 2,  ///< the trouble face's X
};

struct FaceGeometry {
  // The panel both faces are laid out in. The Mac scales this; it does not
  // re-describe it.
  static constexpr int kScreenWidth = 320;
  static constexpr int kScreenHeight = 240;
  static constexpr int kEyeLeftX = 102;
  static constexpr int kEyeRightX = 218;
  static constexpr int kEyeY = 120;

  EyeKind eyeKind = EyeKind::Open;
  /// The eye's size at this moment: the pose for an open eye, the curve's box
  /// for a closed one, the X's reach for a crossed one.
  int eyeWidth = 0;
  int eyeHeight = 0;
  /// How far the lids have come down, 0 open and 100 shut. Whole numbers, so
  /// the two sides cannot disagree about floating point.
  int shut = 0;
  /// Where the pupil sits relative to the eye's centre, and zero when there is
  /// no pupil to place.
  ///
  /// **Deliberately NOT part of the agreement between the two faces**, and so
  /// not in operator== nor in the contract file. Idle gaze is a wander: the
  /// robot's GazeBrain and the Mac's GazePlanner each choose their own resting
  /// points and drift between them on their own clocks. Requiring them to land
  /// on the same pixel would report a difference every frame for something
  /// nobody experiences as a difference. Whether there IS a pupil is part of
  /// the agreement, and eyeKind carries that.
  int pupilX = 0;
  int pupilY = 0;

  bool frownVisible = false;
  int frownY = 0;
  int frownRadius = 0;

  bool mouthVisible = false;
  int mouthX = 0;
  int mouthY = 0;
  /// The mouth's size at this instant. Like the pupil above, **not part of the
  /// agreement**: each side runs its own spring from its own audio at its own
  /// frame rate, so the two are never the same width mid-word and are not
  /// meant to be. That there IS a mouth, and where it sits, is the agreement.
  int mouthWidth = 0;
  int mouthHeight = 0;

  bool operator==(const FaceGeometry& other) const {
    return eyeKind == other.eyeKind && eyeWidth == other.eyeWidth &&
           eyeHeight == other.eyeHeight && shut == other.shut &&
           frownVisible == other.frownVisible && frownY == other.frownY &&
           frownRadius == other.frownRadius &&
           mouthVisible == other.mouthVisible && mouthX == other.mouthX &&
           mouthY == other.mouthY;
  }
  bool operator!=(const FaceGeometry& other) const { return !(*this == other); }
};

}  // namespace stanbot
