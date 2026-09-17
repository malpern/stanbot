/*
 * StanbotEyes: StackChan/M5GFX port companion for esp32-eyes.
 *
 * Based on the dynamic-eye architecture in playfultechnology/esp32-eyes
 * (Alastair Aitchison; original components credited to Luis Llamas).
 * This file is licensed under the GNU Affero General Public License v3.0 or
 * later. See docs/licenses.md for source and licensing notes.
 */
#pragma once

#include <Arduino.h>
#include "GazeBrain.h"
#include "MouthModel.h"

enum class StanbotEmotion : uint8_t {
  Normal, Angry, Glee, Happy, Sad, Worried, Focused, Annoyed, Surprised,
  Skeptic, Frustrated, Unimpressed, Sleepy, Suspicious, Squint, Furious,
  Scared, Awe
};

// Shared renderer for the avatar-only and camera-enabled sketches.
// The renderer is a template so it can use StackChan's M5GFX display without
// coupling this component to a particular M5Unified display type.
class StanbotEyes {
 public:
  void begin(uint32_t now) {
    nextBlinkMs_ = now + 19200;
    lastFrameMs_ = now;
  }

  void attend(float x, float y, uint32_t now) {
    targetX_ = constrain(x, -1.0f, 1.0f);
    targetY_ = constrain(y, -1.0f, 1.0f);
    lastTargetMs_ = now;
    hasTarget_ = true;
  }

  // Blink now, as people do with a large gaze shift, unless one just happened.
  void blinkNow(uint32_t now) {
    if (blinking_ || now - blinkStartedMs_ < 1000) return;
    blinking_ = true;
    blinkStartedMs_ = now;
  }

  // The person being looked at faces the robot (from the Mac's head-pose
  // check). Lapses 900 ms after the last report, like attend().
  void engage(bool engaged, uint32_t now) {
    engaged_ = engaged;
    lastEngagedMs_ = now;
  }

  void setEmotion(StanbotEmotion emotion) { targetPose_ = poseFor(emotion); }

  // A loudness packet from the Mac while it plays speech (MouthModel.h).
  bool mouthReceive(uint32_t sequence, uint8_t open, int8_t shape, uint32_t now) {
    return mouth_.receive(sequence, open, shape, now);
  }

  static bool emotionFromName(const char* name, StanbotEmotion& result) {
    static constexpr const char* kNames[] = {
        "normal", "angry", "glee", "happy", "sad", "worried", "focused",
        "annoyed", "surprised", "skeptic", "frustrated", "unimpressed",
        "sleepy", "suspicious", "squint", "furious", "scared", "awe"};
    for (uint8_t i = 0; i < sizeof(kNames) / sizeof(kNames[0]); ++i) {
      if (strcmp(name, kNames[i]) == 0) {
        result = static_cast<StanbotEmotion>(i);
        return true;
      }
    }
    return false;
  }

  // A face target arrived within the last 900 ms: what the light bar shows.
  bool attending(uint32_t now) const { return hasTarget_ && now - lastTargetMs_ < 900; }

  template <typename Display>
  bool update(Display& display, uint32_t now) {
    if (now - lastFrameMs_ < 33) return false;  // bounded at about 30 fps
    lastFrameMs_ = now;

    const bool attending = hasTarget_ && now - lastTargetMs_ < 900;
    const bool engaged = attending && engaged_ && now - lastEngagedMs_ < 900;
    // Saccades between fixations when no one engages (mostly looking away from
    // a person who is there), smooth pursuit and dilated pupils when someone
    // faces the robot. See GazeBrain.h; no camera claim is implied.
    gaze_.update(now, attending, targetX_, targetY_, engaged);
    lookX_ = gaze_.lookX;
    lookY_ = gaze_.lookY;
    currentPose_.width += (targetPose_.width - currentPose_.width) * 0.10f;
    currentPose_.height += (targetPose_.height - currentPose_.height) * 0.10f;
    currentPose_.tilt += (targetPose_.tilt - currentPose_.tilt) * 0.10f;
    currentPose_.pupilScale +=
        (targetPose_.pupilScale - currentPose_.pupilScale) * 0.10f;

    if (!blinking_ && now >= nextBlinkMs_) {
      blinking_ = true;
      blinkStartedMs_ = now;
    }
    if (blinking_ && now - blinkStartedMs_ >= 180) {
      blinking_ = false;
      nextBlinkMs_ = now + 19200 + random(0, 10800);
    }

    float blink = 0.0f;
    if (blinking_) {
      const float phase = (now - blinkStartedMs_) / 180.0f;
      blink = phase < 0.5f ? phase * 2.0f : (1.0f - phase) * 2.0f;
    }
    mouth_.update(now);
    draw(display, attending, blink);
    return true;
  }

 private:
  float targetX_ = 0.0f;
  float targetY_ = 0.0f;
  float lookX_ = 0.0f;
  float lookY_ = 0.0f;
  uint32_t lastTargetMs_ = 0;
  uint32_t lastFrameMs_ = 0;
  uint32_t nextBlinkMs_ = 0;
  uint32_t blinkStartedMs_ = 0;
  bool blinking_ = false;
  bool hasTarget_ = false;
  bool engaged_ = false;
  uint32_t lastEngagedMs_ = 0;
  stanbot::GazeBrain gaze_{0xC0FFEEu};
  stanbot::MouthModel mouth_;
  struct Pose { float width; float height; float tilt; float pupilScale; };
  Pose currentPose_{86, 112, 0, 1};
  Pose targetPose_{86, 112, 0, 1};

  static Pose poseFor(StanbotEmotion emotion) {
    switch (emotion) {
      case StanbotEmotion::Normal: return {86,112,0,1};
      case StanbotEmotion::Angry: return {90,56,18,0.85f};
      case StanbotEmotion::Glee: return {90,32,-4,0.9f};
      case StanbotEmotion::Happy: return {90,26,0,0.9f};
      case StanbotEmotion::Sad: return {82,48,-14,1.05f};
      case StanbotEmotion::Worried: return {82,72,-8,1.2f};
      case StanbotEmotion::Focused: return {92,42,9,0.7f};
      case StanbotEmotion::Annoyed: return {92,34,12,0.75f};
      case StanbotEmotion::Surprised: return {94,130,0,1.25f};
      case StanbotEmotion::Skeptic: return {82,84,15,0.85f};
      case StanbotEmotion::Frustrated: return {88,32,18,0.7f};
      case StanbotEmotion::Unimpressed: return {94,30,0,0.7f};
      case StanbotEmotion::Sleepy: return {88,30,-10,0.8f};
      case StanbotEmotion::Suspicious: return {84,52,12,0.8f};
      case StanbotEmotion::Squint: return {72,48,0,0.65f};
      case StanbotEmotion::Furious: return {92,62,24,0.65f};
      case StanbotEmotion::Scared: return {92,138,0,1.35f};
      case StanbotEmotion::Awe: return {100,142,0,1.1f};
    }
    return {86,112,0,1};
  }

  template <typename Display>
  void draw(Display& display, bool attending, float blink) {
    constexpr int kBaseY = 120;
    const int width = static_cast<int>(currentPose_.width);
    const int height = max(6, static_cast<int>(currentPose_.height * (1.0f - blink)));
    const int radius = min(30, height / 2);
    const int pupilX = static_cast<int>(lookX_ * 18);
    const int pupilY = static_cast<int>(lookY_ * 12);
    // The irises stay grey whether or not a face is attended to. They turned
    // cyan until 2026-09-17; seeing a face now lights the body's LED bar blue
    // instead (light_bar.h), which the owner found less distracting.
    (void)attending;
    const uint16_t iris = 0xBDF7;

    display.fillScreen(TFT_BLACK);
    drawEye(display, 102, kBaseY, width, height, radius, pupilX, pupilY,
            iris);
    drawEye(display, 218, kBaseY, width, height, radius, pupilX, pupilY,
            iris);
    drawMouth(display);
  }

  // The mouth: a grey capsule a little dimmer than the irises, a thin line at
  // rest, with a dark opening once it is tall enough (MouthModel.h).
  template <typename Display>
  void drawMouth(Display& display) {
    const stanbot::MouthShape m = mouth_.shape();
    constexpr uint16_t kMouthGrey = 0x9CD3;   // about 60% grey; the irises are 0xBDF7
    display.fillRoundRect(m.centerX - m.width / 2, m.centerY - m.height / 2, m.width, m.height,
                          min(m.width, m.height) / 2, kMouthGrey);
    if (m.innerWidth > 0) {
      display.fillRoundRect(m.centerX - m.innerWidth / 2, m.centerY - m.innerHeight / 2,
                            m.innerWidth, m.innerHeight, min(m.innerWidth, m.innerHeight) / 2, TFT_BLACK);
    }
  }

  template <typename Display>
  void drawEye(Display& display, int centerX, int centerY, int width, int height,
               int radius, int pupilX, int pupilY, uint16_t iris) {
    const int top = centerY - height / 2;
    display.fillRoundRect(centerX - width / 2, top, width, height, radius, iris);
    // Dilation widens the pupil, never past the edge of the eye.
    const int dilated = static_cast<int>(min(18, height / 4) * currentPose_.pupilScale * gaze_.dilation);
    const int pupilRadius = max(6, min(dilated, min(width, height) / 2 - 4));
    display.fillCircle(centerX + pupilX, centerY + pupilY, pupilRadius, TFT_BLACK);
    if (height > 24) {
      display.fillCircle(centerX + pupilX - pupilRadius / 3,
                         centerY + pupilY - pupilRadius / 3,
                         max(2, pupilRadius / 5), TFT_WHITE);
    }
    const int tilt = static_cast<int>(currentPose_.tilt);
    if (tilt > 0) display.fillTriangle(centerX - width / 2, top, centerX + width / 2, top,
                                        centerX + width / 2, top + tilt, TFT_BLACK);
    if (tilt < 0) display.fillTriangle(centerX - width / 2, top, centerX + width / 2, top,
                                        centerX - width / 2, top - tilt, TFT_BLACK);
  }
};
