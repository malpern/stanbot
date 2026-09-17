#pragma once

// Stanbot's speaking mouth: what the robot draws while the Mac plays speech.
// Plain C++ with no Arduino dependency, so companion/test_mouth_model.cpp runs
// it on the Mac. The app mirrors these constants (MouthModel.swift) and
// CharacterTests checks them against this file. See docs/voice.md.
//
// The Mac sends a loudness value about 15 times a second over UDP (not the
// command channel, which is only read between camera frames). The opening
// follows it through a critically damped spring; the mouth grows in when
// speech starts and shrinks away after it ends, and closes by itself if the
// packets stop, so a dropped link never leaves it frozen mid-word.

#include <cstdint>
#include <cstring>

namespace stanbot {

struct MouthShape {
  bool visible;
  int centerX, centerY;   // robot display pixels, 320x240
  int width, height;      // the outer grey capsule
  int innerWidth, innerHeight;   // the dark opening inside it; 0 when too small
};

// UDP port and packet: "SBMO", version 1, opening 0-100, sequence (u32 LE).
constexpr uint16_t kMouthPort = 3334;
constexpr size_t kMouthPacketSize = 10;

inline bool parseMouthPacket(const uint8_t* data, size_t length, uint32_t& sequence, uint8_t& value) {
  if (data == nullptr || length != kMouthPacketSize) return false;
  if (memcmp(data, "SBMO", 4) != 0 || data[4] != 1 || data[5] > 100) return false;
  value = data[5];
  sequence = static_cast<uint32_t>(data[6]) | static_cast<uint32_t>(data[7]) << 8 |
             static_cast<uint32_t>(data[8]) << 16 | static_cast<uint32_t>(data[9]) << 24;
  return true;
}

class MouthModel {
 public:
  // Geometry, in robot display pixels. The eyes are centred at y 120 and are
  // at most 142 tall (awe), so their lowest edge is 191.
  static constexpr int kCenterX = 160;
  static constexpr int kCenterY = 212;
  static constexpr float kClosedHeight = 3.0f;
  static constexpr float kOpenHeight = 18.0f;
  static constexpr float kClosedWidth = 36.0f;
  static constexpr float kOpenWidth = 44.0f;
  static constexpr int kRim = 3;                  // grey edge left around the dark opening
  // Timing.
  static constexpr uint32_t kSilenceCloseMs = 400;   // no packet this long: close
  static constexpr uint32_t kFadeMs = 150;           // grow in / shrink away
  static constexpr float kSpringOmega = 28.0f;       // rad/s: syllables, without snapping
  // A sequence this far behind the last, or any sequence after this long a
  // silence, is taken as the app starting over.
  static constexpr uint32_t kRestartGap = 1000;
  static constexpr uint32_t kRestartSilenceMs = 2000;

  // A packet from the Mac. Old or repeated sequences are ignored.
  bool receive(uint32_t sequence, uint8_t value, uint32_t nowMs) {
    if (value > 100) return false;
    if (haveSequence_ && sequence <= lastSequence_ && lastSequence_ - sequence < kRestartGap &&
        nowMs - lastPacketMs_ < kRestartSilenceMs) return false;
    haveSequence_ = true;
    lastSequence_ = sequence;
    target_ = value / 100.0f;
    lastPacketMs_ = nowMs;
    heard_ = true;
    return true;
  }

  void update(uint32_t nowMs) {
    if (!started_) { started_ = true; lastUpdateMs_ = nowMs; }
    float dt = (nowMs - lastUpdateMs_) / 1000.0f;
    lastUpdateMs_ = nowMs;
    if (dt > 0.1f) dt = 0.1f;   // a stalled loop must not fling the spring

    const bool speaking = heard_ && nowMs - lastPacketMs_ < kSilenceCloseMs;
    const float target = speaking ? target_ : 0.0f;
    // Critically damped spring, in small steps for stability.
    for (float left = dt; left > 0.0f; left -= 0.01f) {
      const float step = left < 0.01f ? left : 0.01f;
      const float accel = kSpringOmega * kSpringOmega * (target - open_) - 2.0f * kSpringOmega * velocity_;
      velocity_ += accel * step;
      open_ += velocity_ * step;
    }
    if (open_ < 0.0f) { open_ = 0.0f; if (velocity_ < 0.0f) velocity_ = 0.0f; }
    if (open_ > 1.0f) { open_ = 1.0f; if (velocity_ > 0.0f) velocity_ = 0.0f; }

    // Present while speaking, and until the opening has nearly closed.
    const bool present = speaking || open_ > 0.02f;
    const float fadeStep = dt * 1000.0f / kFadeMs;
    presence_ += present ? fadeStep : -fadeStep;
    if (presence_ < 0.0f) presence_ = 0.0f;
    if (presence_ > 1.0f) presence_ = 1.0f;
  }

  float opening() const { return open_; }
  float presence() const { return presence_; }

  MouthShape shape() const {
    MouthShape s{};
    s.centerX = kCenterX;
    s.centerY = kCenterY;
    // Grows in from the centre: width follows presence, so there is no alpha
    // to fake on a 16-bit display.
    const float width = (kClosedWidth + (kOpenWidth - kClosedWidth) * open_) * presence_;
    const float height = kClosedHeight + (kOpenHeight - kClosedHeight) * open_;
    s.width = static_cast<int>(width + 0.5f);
    s.height = static_cast<int>(height + 0.5f);
    s.visible = presence_ > 0.0f && s.width >= 2;
    const int innerHeight = s.height - 2 * kRim;
    const int innerWidth = s.width - 2 * kRim;
    if (innerHeight >= 2 && innerWidth >= 2) {
      s.innerWidth = innerWidth;
      s.innerHeight = innerHeight;
    }
    return s;
  }

 private:
  float target_ = 0.0f;
  float open_ = 0.0f;
  float velocity_ = 0.0f;
  float presence_ = 0.0f;
  uint32_t lastPacketMs_ = 0;
  uint32_t lastUpdateMs_ = 0;
  uint32_t lastSequence_ = 0;
  bool haveSequence_ = false;
  bool heard_ = false;
  bool started_ = false;
};

}  // namespace stanbot
