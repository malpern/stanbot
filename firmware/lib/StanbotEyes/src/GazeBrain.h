#pragma once
// Where Stanbot's eyes look, moment to moment. Pure (no Arduino, no display),
// so companion/test_gaze_brain.cpp tests it natively; StanbotEyes draws it.
//
// Modelled loosely on how people use their eyes, within what a 30 fps 320x240
// screen can show, and then calmed down deliberately (2026-09-17): the robot
// sits on the desk in front of its owner all day, so it must never pull the
// eye. The lively first tuning (20 ms jumps every 1-2.6 s across most of the
// screen, quarter-second glances, a twitch every second while locked on) was
// accurate to people and a distraction in practice.
//  - Moves glide over about half a second, then hold still for 5-10 s.
//  - With nobody engaging, the gaze drifts a little either side of centre,
//    not resting dead centre, where a person in front would be.
//  - With someone there who is not facing the robot, it mostly rests a little
//    away, with a rare, unhurried look toward them.
//  - When someone faces the robot, the eyes settle on them and follow smoothly,
//    with a barely visible adjustment now and then, and the pupils widen a
//    little. When they turn away the pupils relax, more slowly than they widened.
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
  static constexpr float kDilated = 1.15f;
  static constexpr float kSaccadeMs = 160.0f;     // time constant of a move: ~0.5 s to settle
  static constexpr float kPursuitMs = 250.0f;     // time constant of following
  static constexpr float kDilateMs = 500.0f;      // widening is gentle...
  static constexpr float kRelaxMs = 1500.0f;      // ...relaxing slower still
  static constexpr float kPeekChance = 0.06f;     // an unhurried look toward someone not engaging
  // Top speed, in eye-widths per second. An easing curve alone moves fastest at
  // the start, so a side-to-side change still snapped 0.16 of the screen in one
  // frame; capping speed makes every move start gently.
  static constexpr float kMaxSpeed = 1.5f;

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
        microX_ = uniform(-0.015f, 0.015f);
        microY_ = uniform(-0.01f, 0.01f);
        nextMicroMs_ = nowMs + static_cast<uint32_t>(uniform(4000, 8000));
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
    float dx = (fixX_ - lookX) * r;
    float dy = (fixY_ - lookY) * r;
    const float step = std::sqrt(dx * dx + dy * dy);
    const float limit = kMaxSpeed * dt / 1000.0f;
    if (step > limit && step > 0.0f) {
      dx *= limit / step;
      dy *= limit / step;
    }
    lookX += dx;
    lookY += dy;
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
      // An unhurried look at them, then away again.
      fixX_ = clampUnit(faceX);
      fixY_ = clampUnit(faceY);
      nextSaccadeMs_ = nowMs + static_cast<uint32_t>(uniform(1500, 2500));
      return;
    }
    if (hasFace) {
      // A little away from them, and slightly down, like looking off in thought.
      const float side = faceX > 0.05f ? -1.0f : (faceX < -0.05f ? 1.0f : (next() & 1u ? 1.0f : -1.0f));
      fixX_ = side * uniform(0.2f, 0.45f);
      fixY_ = uniform(0.05f, 0.25f);
    } else {
      // A small drift either side of centre, not resting dead centre.
      const float side = next() & 1u ? 1.0f : -1.0f;
      fixX_ = side * uniform(0.15f, 0.45f);
      fixY_ = uniform(-0.15f, 0.2f);
    }
    nextSaccadeMs_ = nowMs + static_cast<uint32_t>(uniform(5000, 10000));
  }
};

}  // namespace stanbot
