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
  // Coming back from a reboot or a reflash is not a wake: the eyes should be
  // shut when the face first appears and then open, over the same 2.4 s the
  // Mac's own eyes take (EyeAperture.wakeDuration), so the two read as one
  // thing happening rather than two. Asked for 2026-09-18.
  static constexpr uint32_t kBootOpenMs = 2400;

  // Ask for sleep: the eyes start closing now.
  void close(uint32_t nowMs) {
    if (closing_) return;
    const float from = openness(nowMs);
    closing_ = true;
    startedMs_ = nowMs;
    startedFrom_ = from;
  }

  // Ask to wake: the eyes start opening from wherever they are, over `overMs`
  // (the ordinary wake unless something asks for longer).
  void open(uint32_t nowMs, uint32_t overMs = kOpenMs) {
    if (!closing_ && openMs_ == overMs) return;
    const float from = openness(nowMs);
    closing_ = false;
    openMs_ = overMs;
    startedMs_ = nowMs;
    startedFrom_ = from;
  }

  /// Open over the boot-length span. Named for the one caller so the intent
  /// travels with it (StanbotEyes::openAfterBoot).
  void openAfterBootForTest(uint32_t nowMs) { open(nowMs, kBootOpenMs); }

  /// Start shut, with no animation: what the face should be the instant it
  /// appears after a boot, before it opens its eyes on the room.
  void startClosed(uint32_t nowMs) {
    closing_ = true;
    startedMs_ = nowMs - kCloseMs;   // already finished closing
    startedFrom_ = 0.0f;
  }

  // 1 fully open, 0 fully closed.
  float openness(uint32_t nowMs) const {
    const uint32_t elapsed = nowMs - startedMs_;
    const uint32_t span = closing_ ? kCloseMs : openMs_;
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
  uint32_t openMs_ = kOpenMs;
  uint32_t startedMs_ = 0;
  float startedFrom_ = 1.0f;
};

}  // namespace stanbot
