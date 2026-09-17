#pragma once

// Stanbot's mouth: a soft capsule that is always there. At rest it is a thin
// line; while the Mac plays speech it opens with loudness and changes shape
// with the voice's brightness (wider and flatter for "ee" and "s", narrower and
// rounder for "oo"). Through short pauses it stays parted; after speech it eases
// back to the line. It never appears or disappears. See docs/voice.md.
//
// Plain C++ with no Arduino dependency, so companion/test_mouth_model.cpp runs
// it on the Mac. The app mirrors these constants (MouthModel.swift) and
// MouthTests checks them against this file.
//
// All sound analysis happens on the Mac, which sends the finished targets about
// 15 times a second over UDP (not the command channel, which is only read
// between camera frames). The robot only eases toward them and draws.

#include <cstdint>
#include <cstring>

namespace stanbot {

struct MouthShape {
  int centerX, centerY;          // robot display pixels, 320x240
  int width, height;             // the outer grey capsule
  int innerWidth, innerHeight;   // the dark opening inside it; 0 when too small
};

// UDP port and packet: "SBMO", version 2, opening 0-100, shape -100..100
// (int8: - round, + wide), sequence (u32 LE).
constexpr uint16_t kMouthPort = 3334;
constexpr size_t kMouthPacketSize = 11;

inline bool parseMouthPacket(const uint8_t* data, size_t length, uint32_t& sequence, uint8_t& open,
                             int8_t& shape) {
  if (data == nullptr || length != kMouthPacketSize) return false;
  const int8_t s = static_cast<int8_t>(data[6]);
  if (memcmp(data, "SBMO", 4) != 0 || data[4] != 2 || data[5] > 100 || s < -100 || s > 100) return false;
  open = data[5];
  shape = s;
  sequence = static_cast<uint32_t>(data[7]) | static_cast<uint32_t>(data[8]) << 8 |
             static_cast<uint32_t>(data[9]) << 16 | static_cast<uint32_t>(data[10]) << 24;
  return true;
}

class MouthModel {
 public:
  // Geometry, in robot display pixels. The eyes are centred at y 120 and are
  // at most 142 tall (awe), so their lowest edge is 191.
  static constexpr int kCenterX = 160;
  static constexpr int kCenterY = 212;
  static constexpr float kRestWidth = 40.0f;
  static constexpr float kRestHeight = 4.0f;
  static constexpr float kOpenHeight = 22.0f;   // fully open, neutral shape
  static constexpr float kWideWidth = 16.0f;    // added at shape +1
  static constexpr float kRoundWidth = 14.0f;   // removed at shape -1
  static constexpr float kOpenNarrowing = 6.0f; // an open jaw draws the corners in
  static constexpr float kWideFlatten = 0.4f;   // shape +1 takes this share off the opening
  static constexpr float kRoundDeepen = 4.0f;   // shape -1 adds this much height when open
  static constexpr int kRim = 3;                // grey edge left around the dark opening
  // Timing.
  static constexpr uint32_t kSilenceRestMs = 400;  // no packet this long: back to the line
  static constexpr float kSpringOmega = 26.0f;     // rad/s: syllables, without snapping
  // A sequence this far behind the last, or any sequence after this long a
  // silence, is taken as the app starting over.
  static constexpr uint32_t kRestartGap = 1000;
  static constexpr uint32_t kRestartSilenceMs = 2000;

  // A packet from the Mac. Old or repeated sequences are ignored.
  bool receive(uint32_t sequence, uint8_t open, int8_t shape, uint32_t nowMs) {
    if (open > 100 || shape < -100 || shape > 100) return false;
    if (haveSequence_ && sequence <= lastSequence_ && lastSequence_ - sequence < kRestartGap &&
        nowMs - lastPacketMs_ < kRestartSilenceMs) return false;
    haveSequence_ = true;
    lastSequence_ = sequence;
    targetOpen_ = open / 100.0f;
    targetShape_ = shape / 100.0f;
    lastPacketMs_ = nowMs;
    heard_ = true;
    return true;
  }

  void update(uint32_t nowMs) {
    if (!started_) { started_ = true; lastUpdateMs_ = nowMs; }
    float dt = (nowMs - lastUpdateMs_) / 1000.0f;
    lastUpdateMs_ = nowMs;
    if (dt > 0.1f) dt = 0.1f;   // a stalled loop must not fling the springs

    const bool speaking = heard_ && nowMs - lastPacketMs_ < kSilenceRestMs;
    const float goalOpen = speaking ? targetOpen_ : 0.0f;
    const float goalShape = speaking ? targetShape_ : 0.0f;
    // Critically damped springs, in small steps for stability.
    for (float left = dt; left > 0.0f; left -= 0.01f) {
      const float step = left < 0.01f ? left : 0.01f;
      spring(open_, openVelocity_, goalOpen, step);
      spring(shape_, shapeVelocity_, goalShape, step);
    }
    clamp(open_, openVelocity_, 0.0f, 1.0f);
    clamp(shape_, shapeVelocity_, -1.0f, 1.0f);
  }

  float opening() const { return open_; }
  float shapeValue() const { return shape_; }

  // Width and height for an opening and shape; shared with the app.
  static void size(float open, float shape, float& width, float& height) {
    const float wide = shape > 0.0f ? shape : 0.0f;
    const float round = shape < 0.0f ? -shape : 0.0f;
    width = kRestWidth + kWideWidth * wide - kRoundWidth * round * open - kOpenNarrowing * open;
    height = kRestHeight + (kOpenHeight - kRestHeight) * open * (1.0f - kWideFlatten * wide) +
             kRoundDeepen * round * open;
  }

  MouthShape shape() const {
    MouthShape s{};
    s.centerX = kCenterX;
    s.centerY = kCenterY;
    float width = 0.0f, height = 0.0f;
    size(open_, shape_, width, height);
    s.width = static_cast<int>(width + 0.5f);
    s.height = static_cast<int>(height + 0.5f);
    const int innerHeight = s.height - 2 * kRim;
    const int innerWidth = s.width - 2 * kRim;
    if (innerHeight >= 2 && innerWidth >= 2) {
      s.innerWidth = innerWidth;
      s.innerHeight = innerHeight;
    }
    return s;
  }

 private:
  static void spring(float& value, float& velocity, float goal, float step) {
    const float accel = kSpringOmega * kSpringOmega * (goal - value) - 2.0f * kSpringOmega * velocity;
    velocity += accel * step;
    value += velocity * step;
  }
  static void clamp(float& value, float& velocity, float low, float high) {
    if (value < low) { value = low; if (velocity < 0.0f) velocity = 0.0f; }
    if (value > high) { value = high; if (velocity > 0.0f) velocity = 0.0f; }
  }

  float targetOpen_ = 0.0f, targetShape_ = 0.0f;
  float open_ = 0.0f, openVelocity_ = 0.0f;
  float shape_ = 0.0f, shapeVelocity_ = 0.0f;
  uint32_t lastPacketMs_ = 0;
  uint32_t lastUpdateMs_ = 0;
  uint32_t lastSequence_ = 0;
  bool haveSequence_ = false;
  bool heard_ = false;
  bool started_ = false;
};

}  // namespace stanbot
