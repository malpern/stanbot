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

// G,<x>,<y>: look at an image position without moving the head. Rejects
// anything malformed, NaN or out of range.
inline bool parseGazeLine(const char* payload, float& x, float& y) {
  if (payload == nullptr) return false;
  char tail = 0;
  if (std::sscanf(payload, "%f,%f%c", &x, &y, &tail) != 2) return false;
  if (!(x == x) || !(y == y)) return false;
  return x >= -1.0f && x <= 1.0f && y >= -1.0f && y <= 1.0f;
}

}  // namespace stanbot
