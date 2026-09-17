#pragma once
// Where Stanbot's eyes look, moment to moment. Pure (no Arduino, no display),
// so companion/test_gaze_brain.cpp tests it natively; StanbotEyes draws it.
//
// Modelled loosely on how people use their eyes, within what a 30 fps 320x240
// screen can show:
//  - Eyes do not glide; they jump (saccades, tens of milliseconds) between
//    fixations and hold still in between.
//  - With nobody engaging, the gaze wanders the room and avoids staring at
//    the middle of the view, which is where a person in front would be.
//  - With someone there who is not facing the robot, it mostly looks away,
//    with an occasional brief, shy glance toward them.
//  - When someone faces the robot, the eyes lock on and follow them smoothly
//    (pursuit), with tiny micro-saccades, and the pupils dilate. When they
//    turn away the pupils relax, more slowly than they widened.
//
// "Engaged" comes from the Mac: a face turned toward the camera, held for
// several frames (the app's head-pose check). It is not eye contact, and the
// eyes are an expression of attention, not a measurement.
#include <cmath>
#include <cstdint>

namespace stanbot {

struct GazeBrain {
  // Outputs, -1...1 (+x right, +y down), and pupil scale.
  float lookX = 0.0f, lookY = 0.0f;
  float dilation = 1.0f;

  // Tunables, shared in spirit with the Mac (docs/app-design.md).
  static constexpr float kDilated = 1.38f;
  static constexpr float kSaccadeMs = 22.0f;      // time constant of a jump
  static constexpr float kPursuitMs = 90.0f;      // time constant of following
  static constexpr float kDilateMs = 140.0f;      // widening is quick...
  static constexpr float kRelaxMs = 520.0f;       // ...relaxing is slow
  static constexpr float kPeekChance = 0.22f;     // shy glance toward someone not engaging

  explicit GazeBrain(uint32_t seed = 0x9E3779B9u) : rng_(seed ? seed : 1u) {}

  // Advance to `nowMs`. `hasFace`: a face is present at (faceX, faceY), in the
  // eyes' own frame (already mirrored for the display). `engaged`: it faces us.
  void update(uint32_t nowMs, bool hasFace, float faceX, float faceY, bool engaged) {
    const float dt = started_ ? static_cast<float>(nowMs - lastMs_) : 0.0f;
    started_ = true;
    lastMs_ = nowMs;
    const bool locked = engaged && hasFace;

    if (locked) {
      // Follow the face, with a micro-saccade now and then so it never looks frozen.
      if (nowMs >= nextMicroMs_) {
        microX_ = uniform(-0.04f, 0.04f);
        microY_ = uniform(-0.03f, 0.03f);
        nextMicroMs_ = nowMs + static_cast<uint32_t>(uniform(700, 1400));
      }
      fixX_ = clampUnit(faceX + microX_);
      fixY_ = clampUnit(faceY + microY_);
      nextSaccadeMs_ = nowMs;   // pick a fresh fixation straight away if we lose them
      approach(dt, kPursuitMs);
    } else {
      if (nowMs >= nextSaccadeMs_) chooseFixation(nowMs, hasFace, faceX, faceY);
      approach(dt, kSaccadeMs);
    }

    const float target = locked ? kDilated : 1.0f;
    dilation += (target - dilation) * rate(dt, target > dilation ? kDilateMs : kRelaxMs);
  }

 private:
  uint32_t rng_;
  uint32_t lastMs_ = 0;
  bool started_ = false;
  uint32_t nextSaccadeMs_ = 0, nextMicroMs_ = 0;
  float fixX_ = 0.0f, fixY_ = 0.0f;
  float microX_ = 0.0f, microY_ = 0.0f;

  static float clampUnit(float v) { return v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v); }
  static float rate(float dtMs, float tauMs) { return dtMs <= 0.0f ? 0.0f : 1.0f - std::exp(-dtMs / tauMs); }

  void approach(float dt, float tauMs) {
    const float r = rate(dt, tauMs);
    lookX += (fixX_ - lookX) * r;
    lookY += (fixY_ - lookY) * r;
  }

  uint32_t next() {   // xorshift32
    rng_ ^= rng_ << 13;
    rng_ ^= rng_ >> 17;
    rng_ ^= rng_ << 5;
    return rng_;
  }
  float uniform(float low, float high) { return low + (high - low) * (next() % 10000) / 10000.0f; }

  void chooseFixation(uint32_t nowMs, bool hasFace, float faceX, float faceY) {
    if (hasFace && uniform(0, 1) < kPeekChance) {
      // A shy glance at them, held briefly, then away again.
      fixX_ = clampUnit(faceX);
      fixY_ = clampUnit(faceY);
      nextSaccadeMs_ = nowMs + static_cast<uint32_t>(uniform(260, 520));
      return;
    }
    if (hasFace) {
      // Away from them: the other side, and a little down, like looking off in thought.
      const float side = faceX > 0.05f ? -1.0f : (faceX < -0.05f ? 1.0f : (next() & 1u ? 1.0f : -1.0f));
      fixX_ = side * uniform(0.45f, 0.9f);
      fixY_ = uniform(0.1f, 0.55f);
    } else {
      // Around the room, never resting on the middle of the view.
      const float side = next() & 1u ? 1.0f : -1.0f;
      fixX_ = side * uniform(0.3f, 0.9f);
      fixY_ = uniform(-0.35f, 0.5f);
    }
    nextSaccadeMs_ = nowMs + static_cast<uint32_t>(uniform(900, 2600));
  }
};

}  // namespace stanbot
