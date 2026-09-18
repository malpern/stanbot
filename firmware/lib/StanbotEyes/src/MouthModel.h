#pragma once

// Stanbot's mouth, shown only while it speaks. Speech grows it in from the
// centre as a thin line; it opens with loudness and changes shape with the
// voice's brightness (wider and flatter for "ee" and "s", narrower and rounder
// for "oo"), stays parted through short pauses, and after speech eases back to
// the line and shrinks away. See docs/voice.md.
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
  bool visible;
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

// Two ways to draw the same speech. The owner asked for the second on
// 2026-09-17: "more like a speaker grill with sound lines coming from it".
//
// The argument for it is that Stanbot's eyes are frankly abstract -- two
// rounded rectangles -- so a mouth that gestures at lips is the one part
// pretending to be anatomy. A grille is honest about what it is. The cost is
// that a mouth can show *valence* and a speaker cannot, so the grille leans
// instead (`tilt`): slots sagging when sad, lifting when pleased. That buys
// back most of what a frown was doing, and the eyes were carrying the rest
// anyway.
enum class MouthStyle : uint8_t { Capsule = 0, Grille = 1 };

// The grille, in robot display pixels. A body with horizontal slots, and short
// arcs either side that appear with loudness -- two a side, not an equaliser:
// the owner has asked for calm throughout and radiating lines are the easiest
// thing in the world to make busy.
struct GrilleShape {
  bool visible;
  int centerX, centerY;
  int width, height;
  int slotCount;                 // horizontal slots drawn inside the body
  int slotWidth, slotHeight;
  int slotSpacing;               // centre to centre
  int tilt;                      // pixels the outer slots drop (+) or lift (-)
  int arcCount;                  // 0..kMaxArcs each side
  int arcLength, arcThickness, arcGap;
};

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
  static constexpr uint32_t kFadeMs = 150;         // grow in from the centre / shrink away
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

    // Present while speaking, and until it has eased back to the resting line.
    const bool present = speaking || open_ > 0.02f || shape_ > 0.02f || shape_ < -0.02f;
    const float fade = dt * 1000.0f / kFadeMs;
    presence_ += present ? fade : -fade;
    if (presence_ < 0.0f) presence_ = 0.0f;
    if (presence_ > 1.0f) presence_ = 1.0f;
  }

  float presence() const { return presence_; }

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

  // Emotional lean, -1 sad to +1 pleased. The eyes know the expression; the
  // grille only needs to know which way to sag.
  void setMood(float mood) { mood_ = mood < -1.0f ? -1.0f : (mood > 1.0f ? 1.0f : mood); }
  float mood() const { return mood_; }

  static constexpr int kGrilleWidth = 74;      // wider than the capsule: a panel, not a feature
  static constexpr int kGrilleHeight = 26;
  static constexpr int kGrilleSlots = 3;
  static constexpr int kSlotThickness = 3;
  static constexpr int kGrilleRim = 6;         // body edge left around the slots
  static constexpr int kMaxArcs = 2;           // each side. Two, deliberately.
  static constexpr int kArcThickness = 3;
  static constexpr int kArcGap = 6;
  static constexpr int kArcMinLength = 4;
  static constexpr int kArcMaxLength = 11;
  static constexpr float kArcFirstAt = 0.18f;  // loudness at which one arc appears
  static constexpr float kArcSecondAt = 0.55f; // and the second
  static constexpr int kMaxTilt = 4;           // how far a mood bends the slots

  /// The grille for the current speech and mood. Like the capsule it grows in
  /// from the centre, so the two styles arrive and leave the same way.
  GrilleShape grille() const {
    GrilleShape g{};
    g.centerX = kCenterX;
    g.centerY = kCenterY;
    const float width = kGrilleWidth * presence_;
    g.width = static_cast<int>(width + 0.5f);
    g.height = kGrilleHeight;
    g.visible = presence_ > 0.0f && g.width >= 2 * kGrilleRim + 2;
    if (!g.visible) return g;

    g.slotCount = kGrilleSlots;
    g.slotHeight = kSlotThickness;
    g.slotWidth = g.width - 2 * kGrilleRim;
    // Louder speech opens the slots apart, the way a cone moves: the body stays
    // the same size, so the panel does not breathe in and out.
    const int span = g.height - 2 * kSlotThickness;
    const float spread = 0.45f + 0.55f * open_;
    g.slotSpacing = static_cast<int>(span * spread / (kGrilleSlots - 1) + 0.5f);
    g.tilt = static_cast<int>(-mood_ * kMaxTilt + (mood_ < 0 ? -0.5f : 0.5f));

    // Sound coming out: one arc from kArcFirstAt, a second from kArcSecondAt,
    // each longer the louder it is. Brightness (shape) stretches them a little,
    // so an "ee" reaches further than an "oo" at the same loudness.
    g.arcCount = open_ >= kArcSecondAt ? 2 : (open_ >= kArcFirstAt ? 1 : 0);
    const float reach = open_ * (1.0f + 0.25f * (shape_ > 0.0f ? shape_ : 0.0f));
    g.arcLength = kArcMinLength + static_cast<int>((kArcMaxLength - kArcMinLength) * reach + 0.5f);
    if (g.arcLength > kArcMaxLength) g.arcLength = kArcMaxLength;
    g.arcThickness = kArcThickness;
    g.arcGap = kArcGap;
    return g;
  }

  MouthShape shape() const {
    MouthShape s{};
    s.centerX = kCenterX;
    s.centerY = kCenterY;
    float width = 0.0f, height = 0.0f;
    size(open_, shape_, width, height);
    width *= presence_;   // grows in from the centre: no alpha on a 16-bit display
    s.width = static_cast<int>(width + 0.5f);
    s.visible = presence_ > 0.0f && s.width >= 2;
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
  float mood_ = 0.0f;

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
  float presence_ = 0.0f;
  uint32_t lastPacketMs_ = 0;
  uint32_t lastUpdateMs_ = 0;
  uint32_t lastSequence_ = 0;
  bool haveSequence_ = false;
  bool heard_ = false;
  bool started_ = false;
};

}  // namespace stanbot
