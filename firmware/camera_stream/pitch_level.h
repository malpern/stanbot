#pragma once
// C,PITCHLEVEL,<raw>: move pitch to one absolute raw position and hold it for a
// few seconds, so a person can judge by eye whether the head is level. It
// exists to establish pitchRest (checklist step 2), which nothing else can
// measure. Pure, so companion/test_pitch_level.cpp tests it natively.
//
// The accepted range is the one following already allows a session to start
// in (head_tracker.h): 596..672. Every unpowered rest seen so far (601, 620,
// 621, 639, 640) is inside it, and 620 is the BSP's 0 degrees. USB only, like
// every C, command; one power window per boot like the other supervised plans.
#include <cstdio>

namespace stanbot {

constexpr int kPitchLevelLow = 596;
constexpr int kPitchLevelHigh = 672;
constexpr unsigned kPitchLevelHoldMs = 4000;
// Largest move from the measured start a single request may make (15 degrees).
// Unpowered rests seen so far span 601..640, so every candidate the finder
// bisects to near a typical rest is within reach; a request far outside that
// is refused before torque rather than swinging the head.
constexpr int kPitchLevelMaxTravel = 48;

inline bool parsePitchLevel(const char* payload, int& raw) {
  if (payload == nullptr) return false;
  if (std::snprintf(nullptr, 0, "%s", payload) > 3) return false;   // three digits at most, before sscanf can overflow
  int value = 0;
  int consumed = 0;
  if (std::sscanf(payload, "%d%n", &value, &consumed) != 1 || payload[consumed] != '\0') return false;
  if (payload[0] < '0' || payload[0] > '9') return false;   // no sign, no spaces
  if (value < kPitchLevelLow || value > kPitchLevelHigh) return false;
  raw = value;
  return true;
}

}  // namespace stanbot
