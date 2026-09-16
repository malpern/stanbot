#pragma once
#include <cstdint>

namespace stanbot {

// Decides which captured frames to send so the stream averages the requested
// interval. Pure, tested natively by companion/test_frame_pacer.cpp.
//
// The sensor delivers a frame about every 192 ms and the loop sees every one.
// The first version scheduled the next send `interval` after the last one and
// sent only frames at or past that time. At 200 ms a frame always arrived about
// 8 ms early, so every other frame was dropped and the rate halved to 2.6 fps.
// Nobody saw it while encoding took ~190 ms, because by the time the next frame
// was dequeued the deadline had always passed. The faster encoder exposed it.
//
// So: keep a cadence (deadline advances by exactly one interval), accept a frame
// that arrives up to `slack` early, and resynchronise rather than burst when the
// stream has fallen a whole interval behind.
struct FramePacer {
  uint32_t nextMs = 0;
  bool started = false;

  static uint32_t slackFor(uint32_t intervalMs) {
    const uint32_t half = intervalMs / 2;
    return half < 100 ? half : 100;
  }

  bool due(uint32_t nowMs, uint32_t intervalMs) const {
    return !started || static_cast<int32_t>(nowMs + slackFor(intervalMs) - nextMs) >= 0;
  }

  // Call when a frame is sent.
  void sent(uint32_t nowMs, uint32_t intervalMs) {
    if (!started) { started = true; nextMs = nowMs + intervalMs; return; }
    nextMs += intervalMs;
    if (static_cast<int32_t>(nowMs - nextMs) >= 0) nextMs = nowMs + intervalMs;
  }

  void reset() { started = false; nextMs = 0; }
};

}  // namespace stanbot
