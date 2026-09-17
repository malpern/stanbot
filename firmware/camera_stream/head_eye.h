#pragma once
// Eyes lead, head follows, gaze stays put. Pure, tested natively by
// companion/test_head_eye.cpp.
//
// When a person's attention moves, the eyes jump first and the head follows
// more slowly; as the head arrives the eyes turn back the other way, so the
// gaze stays on the target the whole time. Stanbot's eyes already jump in tens
// of milliseconds and the head eases over a few hundred, so the order comes for
// free. What does not: the eyes aim at where the face was in a camera frame
// taken ~300 ms ago, and the head (which carries the camera) has turned since.
// Without correction the eyes overshoot while the head turns and swing back as
// new frames arrive. This corrects the eyes for the head's motion since that
// frame, in image units, using the same raw-per-unit estimates as HeadTracker.
//
// Signs, all measured (head_tracker.h): +raw yaw turns the head to the robot's
// right, and a face to the robot's right is at +x in the image, so turning
// right moves the face toward -x. +raw pitch (with pitchUpSign +1) tilts up,
// and tilting up moves the face down the image, toward +y.
#include "head_tracker.h"

namespace stanbot {

struct ImageOffset { float x, y; };

// Where the face is now, in image units, given where it was in a frame and how
// far the head has turned since. Clamped to the image.
inline ImageOffset compensateForHead(float frameX, float frameY, int yawThen, int yawNow,
                                     int pitchThen, int pitchNow,
                                     const FollowLimits& limits, const FollowConfig& config) {
  const float dx = static_cast<float>(yawNow - yawThen) / static_cast<float>(config.rawPerUnitX);
  const float dy = static_cast<float>(pitchNow - pitchThen) * static_cast<float>(limits.pitchUpSign) /
                   static_cast<float>(config.rawPerUnitY);
  auto clamp = [](float v) { return v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v); };
  return {clamp(frameX - dx), clamp(frameY + dy)};
}

// A gaze shift large enough that people usually blink with it: about 15
// degrees of head travel (the BSP maps 16 raw to 5 degrees).
constexpr int kBlinkShiftRaw = 48;

inline bool largeGazeShift(int yawFrom, int yawTo, int pitchFrom, int pitchTo) {
  const int dy = yawTo - yawFrom, dp = pitchTo - pitchFrom;
  return dy * dy + dp * dp >= kBlinkShiftRaw * kBlinkShiftRaw;
}

}  // namespace stanbot
