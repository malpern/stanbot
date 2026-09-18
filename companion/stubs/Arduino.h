// Just enough Arduino for the firmware headers to compile on the Mac, so the
// drawing and model code can be tested without a robot. Only what those
// headers actually use -- this is a test fixture, not an emulator.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

using std::max;
using std::min;

// The test supplies the clock, so it can put the eyes anywhere in an animation.
extern uint32_t stanbot_test_now_ms;
inline uint32_t millis() { return stanbot_test_now_ms; }

#ifndef TFT_BLACK
#define TFT_BLACK 0x0000
#define TFT_WHITE 0xFFFF
#endif

template <typename T, typename Low, typename High>
inline T constrain(T value, Low low, High high) {
  return value < static_cast<T>(low) ? static_cast<T>(low)
       : value > static_cast<T>(high) ? static_cast<T>(high) : value;
}

// Deterministic on purpose: a test that blinks at random is a test that fails
// at random. The blink schedule is not what these tests are about.
inline long random(long low, long high) { return low + (high - low) / 2; }
