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
#include "SleepCurtain.h"

enum class StanbotEmotion : uint8_t {
  Normal, Angry, Glee, Happy, Sad, Worried, Focused, Annoyed, Surprised,
  Skeptic, Frustrated, Unimpressed, Sleepy, Suspicious, Squint, Furious,
  Scared, Awe,
  // Something went wrong: crossed-out eyes and a frown, after the Sad Mac.
  Trouble
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

  void setEmotion(StanbotEmotion emotion) {
    emotion_ = emotion;
    targetPose_ = poseFor(emotion);
  }

  // Sleep: the eyes close over SleepCurtain::kCloseMs, and only then may the
  // screen go dark (closedForSleep). Waking opens them again.
  void beginSleep(uint32_t now) { curtain_.close(now); }
  void endSleep(uint32_t now) { curtain_.open(now); }
  bool closedForSleep(uint32_t now) const { return curtain_.closed(now); }
  // The lids are all the way up. The head must not move before this: Stanbot
  // opens its eyes, and only then looks around (asked for 2026-09-17).
  bool eyesOpen(uint32_t now) const { return curtain_.openness(now) >= 1.0f; }

  /// The face has just appeared after a boot: start with the eyes shut, and
  /// wait to be told when to open them. A face that pops in already awake
  /// skips the moment it becomes awake, which is the only interesting part.
  void beginClosed(uint32_t now) { curtain_.startClosed(now); }

  /// Open on the room, slowly, the way the Mac's own eyes do.
  void openAfterBoot(uint32_t now) { curtain_.open(now, stanbot::SleepCurtain::kBootOpenMs); }

  // Which mouth to draw. Public because the sketch switches it at runtime
  // (C,MOUTH,...), so the two can be compared by eye on the robot.
  void setMouthStyle(stanbot::MouthStyle style) { mouthStyle_ = style; }
  stanbot::MouthStyle mouthStyle() const { return mouthStyle_; }

  // A loudness packet from the Mac while it plays speech (MouthModel.h).
  bool mouthReceive(uint32_t sequence, uint8_t open, int8_t shape, uint32_t now) {
    return mouth_.receive(sequence, open, shape, now);
  }

  static bool emotionFromName(const char* name, StanbotEmotion& result) {
    static constexpr const char* kNames[] = {
        "normal", "angry", "glee", "happy", "sad", "worried", "focused",
        "annoyed", "surprised", "skeptic", "frustrated", "unimpressed",
        "sleepy", "suspicious", "squint", "furious", "scared", "awe", "trouble"};
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
  stanbot::SleepCurtain curtain_;
  stanbot::MouthStyle mouthStyle_ = stanbot::MouthStyle::Capsule;
  StanbotEmotion emotion_ = StanbotEmotion::Normal;
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
      case StanbotEmotion::Trouble: return {86,112,0,1};
    }
    return {86,112,0,1};
  }

  template <typename Display>
  void draw(Display& display, bool attending, float blink) {
    constexpr int kBaseY = 120;
    const int width = static_cast<int>(currentPose_.width);
    // The sleep curtain closes the lids the same way a blink does, but slowly
    // and all the way (SleepCurtain.h).
    const float lids = (1.0f - blink) * curtain_.openness(lastFrameMs_);
    const int height = max(2, static_cast<int>(currentPose_.height * lids));
    const int radius = min(30, height / 2);
    const int pupilX = static_cast<int>(lookX_ * 18);
    const int pupilY = static_cast<int>(lookY_ * 12);
    // The irises stay grey whether or not a face is attended to. They turned
    // cyan until 2026-09-17; seeing a face now lights the body's LED bar blue
    // instead (light_bar.h), which the owner found less distracting.
    (void)attending;
    const uint16_t iris = 0xBDF7;

    display.fillScreen(TFT_BLACK);
    if (emotion_ == StanbotEmotion::Trouble) {
      drawTrouble(display, iris);
      return;
    }
    // Nearly shut: a curved lid, not a squashed eye. The Mac draws closed eyes
    // as a sagging arc (StanbotEyes.swift, ClosedEye) and the robot flattened
    // to a 2 px bar instead, so falling asleep read as the picture collapsing
    // rather than as eyes closing. Asked for 2026-09-18: make them match.
    if (lids <= kClosedLidsFrom) {
      // Sag grows in as the last of the opening goes, so the rounded eye melts
      // into the curve instead of popping into it.
      const float shut = 1.0f - lids / kClosedLidsFrom;
      drawClosedEye(display, 102, kBaseY, shut, iris);
      drawClosedEye(display, 218, kBaseY, shut, iris);
      drawMouth(display);
      return;
    }
    drawEye(display, 102, kBaseY, width, height, radius, pupilX, pupilY,
            iris);
    drawEye(display, 218, kBaseY, width, height, radius, pupilX, pupilY,
            iris);
    drawMouth(display);
  }

  // Something went wrong: two crossed-out eyes where the eyes were, and a
  // frown below, after the Sad Mac. Still, so it reads as a state, not a mood.
  template <typename Display>
  void drawTrouble(Display& display, uint16_t iris) {
    constexpr int kBaseY = 120;
    constexpr int kArm = 30;     // half the width of each X
    constexpr int kStroke = 6;   // half the line width
    for (int centreX : {102, 218}) {
      display.drawWideLine(centreX - kArm, kBaseY - kArm, centreX + kArm, kBaseY + kArm, kStroke, iris);
      display.drawWideLine(centreX - kArm, kBaseY + kArm, centreX + kArm, kBaseY - kArm, kStroke, iris);
    }
    // The frown: the upper part of a ring centred below the mouth line, so the
    // ends turn down. Angles run clockwise from 3 o'clock in M5GFX.
    display.fillArc(160, 232, 22, 30, 190, 350, iris);
  }

  // The mouth, only while speaking. Two styles, switchable at runtime so they
  // can be compared by eye on the robot rather than argued about (C,MOUTH,...).
  template <typename Display>
  void drawMouth(Display& display) {
    if (mouthStyle_ == stanbot::MouthStyle::Grille) { drawGrille(display); return; }
    const stanbot::MouthShape m = mouth_.shape();
    if (!m.visible) return;
    constexpr uint16_t kMouthGrey = 0x9CD3;   // about 60% grey; the irises are 0xBDF7
    display.fillRoundRect(m.centerX - m.width / 2, m.centerY - m.height / 2, m.width, m.height,
                          min(m.width, m.height) / 2, kMouthGrey);
    if (m.innerWidth > 0) {
      display.fillRoundRect(m.centerX - m.innerWidth / 2, m.centerY - m.innerHeight / 2,
                            m.innerWidth, m.innerHeight, min(m.innerWidth, m.innerHeight) / 2, TFT_BLACK);
    }
  }

  // A speaker panel rather than a face: a dark body with slots, and short arcs
  // either side that appear with loudness. The slots sag or lift with mood,
  // which is the grille's only way to say how it feels -- a speaker cannot
  // frown, so it leans.
  template <typename Display>
  void drawGrille(Display& display) {
    const stanbot::GrilleShape g = mouth_.grille();
    if (!g.visible) return;
    constexpr uint16_t kBody = 0x4208;    // dark, like a real grille: it sits in the face
    constexpr uint16_t kSlot = 0x9CD3;    // the same grey the capsule used
    display.fillRoundRect(g.centerX - g.width / 2, g.centerY - g.height / 2, g.width, g.height,
                          min(g.width, g.height) / 3, kBody);
    const int first = g.centerY - (g.slotCount - 1) * g.slotSpacing / 2;
    for (int index = 0; index < g.slotCount; ++index) {
      const int y = first + index * g.slotSpacing;
      // Mood BOWS each slot: the ends drop for sad and lift for pleased, so the
      // three lines read as a frown or a smile. Moving whole slots apart --
      // which this did first -- looks like the panel opening, which is
      // loudness, and says nothing about how it feels. The Mac draws a smooth
      // curve (StanbotGrille.metal); here it is three steps, which is what an
      // ESP32 painting a 16-bit sprite can afford and reads the same at arm's
      // length.
      const int third = g.slotWidth / 3;
      for (int part = -1; part <= 1; ++part) {
        const int lift = part == 0 ? 0 : g.tilt;   // ends only
        const int x = g.centerX + part * third - third / 2;
        display.fillRoundRect(x, y - g.slotHeight / 2 + lift, third, g.slotHeight,
                              g.slotHeight / 2, kSlot);
      }
    }
    for (int arc = 0; arc < g.arcCount; ++arc) {
      const int offset = g.width / 2 + g.arcGap + arc * (g.arcThickness + g.arcGap);
      const int height = g.arcLength;
      for (int side = -1; side <= 1; side += 2) {
        const int x = g.centerX + side * offset - (side < 0 ? g.arcThickness : 0);
        display.fillRoundRect(x, g.centerY - height / 2, g.arcThickness, height,
                              g.arcThickness / 2, kSlot);
      }
    }
  }

  // A closed eye: the same sagging curve the Mac draws, so the two faces read
  // as one character. Geometry is taken from the Mac's ClosedEye rather than
  // invented -- at the robot's own 320x240 scale that curve is 70 wide with a
  // 17.6 sag, which is a circular arc of radius 44 swept 53 degrees either side
  // of straight down. Angles run clockwise from 3 o'clock in M5GFX, so
  // straight down is 90.
  static constexpr int kClosedWidth = 70;
  static constexpr int kClosedSag = 18;
  static constexpr int kClosedStroke = 9;      // the Mac's lineWidth
  /// Below this much lid left, the eye is drawn as the curve.
  static constexpr float kClosedLidsFrom = 0.16f;

  template <typename Display>
  void drawClosedEye(Display& display, int centerX, int centerY, float shut, uint16_t iris) {
    if (shut < 0.0f) shut = 0.0f;
    if (shut > 1.0f) shut = 1.0f;
    // A flat bar at the moment of the switch, the full curve once shut.
    const int sag = static_cast<int>(kClosedSag * shut);
    const int half = kClosedWidth / 2;
    if (sag < 2) {
      display.fillRoundRect(centerX - half, centerY - kClosedStroke / 2, kClosedWidth,
                            kClosedStroke, kClosedStroke / 2, iris);
      return;
    }
    // Radius and sweep for this sag, so the ends stay put while the middle
    // drops: R from the sagitta, the half angle from asin(half / R).
    const float radius = (static_cast<float>(half) * half + static_cast<float>(sag) * sag)
                         / (2.0f * sag);
    float ratio = half / radius;
    if (ratio > 1.0f) ratio = 1.0f;
    const int sweep = static_cast<int>(asinf(ratio) * 180.0f / 3.14159265f);
    const int arcCentreY = centerY + sag / 2 - static_cast<int>(radius);
    const int inner = static_cast<int>(radius) - kClosedStroke / 2;
    const int outer = inner + kClosedStroke;
    display.fillArc(centerX, arcCentreY, inner, outer, 90 - sweep, 90 + sweep, iris);
    // The Mac's stroke has round caps; fillArc ends square, and at this weight
    // the difference is visible as a clipped tip.
    for (int side = -1; side <= 1; side += 2) {
      const float angle = (90 + side * sweep) * 3.14159265f / 180.0f;
      const int capX = centerX + static_cast<int>(cosf(angle) * radius);
      const int capY = arcCentreY + static_cast<int>(sinf(angle) * radius);
      display.fillCircle(capX, capY, kClosedStroke / 2, iris);
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
