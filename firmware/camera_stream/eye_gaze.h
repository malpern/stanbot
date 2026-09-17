#pragma once
// Where the on-screen eyes look for a face at an image position. Pure, so it is
// tested natively by companion/test_eye_gaze.cpp.
//
// Image coordinates are the follow-target ones: x and y in [-1, 1], -1 at the
// left and top of the captured frame. The display faces the same way as the
// camera, toward the person. A person on the robot's right appears on the
// right of the image (measured 2026-09-15, docs/head-following.md) but on the
// viewer's LEFT of the screen, so the pupils move left: gaze x is -image x.
// That mirror is reasoned from the measured image orientation, not yet seen on
// the robot. Up is the same on both: gaze y is image y (pupils draw at +y down).
#include <cstdio>

namespace stanbot {

constexpr float kGazeConfidence = 0.70f;   // same threshold the head attends at

struct Gaze { float x, y; };

inline float clampUnit(float value) { return value < -1.0f ? -1.0f : (value > 1.0f ? 1.0f : value); }

inline Gaze gazeForImage(float x, float y) { return {clampUnit(-x), clampUnit(y)}; }

// G,<x>,<y>[,<engaged>]: look at an image position without moving the head.
// `engaged` is 1 when the person faces the robot (the Mac's head-pose check),
// 0 or absent otherwise. Rejects anything malformed, NaN or out of range.
inline bool parseGazeLine(const char* payload, float& x, float& y, bool& engaged) {
  if (payload == nullptr) return false;
  char tail = 0;
  int flag = 0;
  const int fields = std::sscanf(payload, "%f,%f,%d%c", &x, &y, &flag, &tail);
  if (fields == 2) {
    if (std::sscanf(payload, "%f,%f%c", &x, &y, &tail) != 2) return false;
    flag = 0;
  } else if (fields != 3 || (flag != 0 && flag != 1)) {
    return false;
  }
  if (!(x == x) || !(y == y)) return false;
  engaged = flag == 1;
  return x >= -1.0f && x <= 1.0f && y >= -1.0f && y <= 1.0f;
}

inline bool parseGazeLine(const char* payload, float& x, float& y) {
  bool engaged = false;
  return parseGazeLine(payload, x, y, engaged);
}

}  // namespace stanbot
