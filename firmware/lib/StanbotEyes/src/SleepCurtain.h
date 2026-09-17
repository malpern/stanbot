#pragma once

// Stanbot closing and opening its eyes around sleep. The screen only goes dark
// once the eyes have shut, so sleeping reads as falling asleep rather than as a
// power cut; waking opens them again, a little faster.
//
// Plain C++ with no Arduino dependency, so companion/test_sleep_curtain.cpp
// runs it on the Mac.

#include <cstdint>

namespace stanbot {

class SleepCurtain {
 public:
  static constexpr uint32_t kCloseMs = 700;   // eyes closing, before the screen darkens
  static constexpr uint32_t kOpenMs = 400;    // and opening again on wake

  // Ask for sleep: the eyes start closing now.
  void close(uint32_t nowMs) {
    if (closing_) return;
    const float from = openness(nowMs);
    closing_ = true;
    startedMs_ = nowMs;
    startedFrom_ = from;
  }

  // Ask to wake: the eyes start opening from wherever they are.
  void open(uint32_t nowMs) {
    if (!closing_) return;
    const float from = openness(nowMs);
    closing_ = false;
    startedMs_ = nowMs;
    startedFrom_ = from;
  }

  // 1 fully open, 0 fully closed.
  float openness(uint32_t nowMs) const {
    const uint32_t elapsed = nowMs - startedMs_;
    const uint32_t span = closing_ ? kCloseMs : kOpenMs;
    const float goal = closing_ ? 0.0f : 1.0f;
    if (elapsed >= span) return goal;
    const float t = static_cast<float>(elapsed) / static_cast<float>(span);
    // Ease in and out, so the lids neither snap nor crawl.
    const float eased = t * t * (3.0f - 2.0f * t);
    return startedFrom_ + (goal - startedFrom_) * eased;
  }

  bool asleepWanted() const { return closing_; }

  // The screen may go dark: the eyes are shut.
  bool closed(uint32_t nowMs) const { return closing_ && openness(nowMs) <= 0.0f; }

 private:
  bool closing_ = false;
  uint32_t startedMs_ = 0;
  float startedFrom_ = 1.0f;
};

}  // namespace stanbot
