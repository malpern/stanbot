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

// The renderer is a template so it can use StackChan's M5GFX display without
// coupling this component to a particular M5Unified display type.
class StanbotEyes {
 public:
  void begin(uint32_t now) {
    nextBlinkMs_ = now + 3200;
    lastFrameMs_ = now;
  }

  void attend(float x, float y, uint32_t now) {
    targetX_ = constrain(x, -1.0f, 1.0f);
    targetY_ = constrain(y, -1.0f, 1.0f);
    lastTargetMs_ = now;
  }

  template <typename Display>
  bool update(Display& display, uint32_t now) {
    if (now - lastFrameMs_ < 33) return false;  // bounded at about 30 fps
    lastFrameMs_ = now;

    const bool attending = now - lastTargetMs_ < 900;
    if (!attending) {
      // Quiet local idle drift; no network or camera claim is implied.
      targetX_ = sinf(now / 2400.0f) * 0.18f;
      targetY_ = sinf(now / 3100.0f) * 0.08f;
    }
    lookX_ += (targetX_ - lookX_) * 0.14f;
    lookY_ += (targetY_ - lookY_) * 0.14f;

    if (!blinking_ && now >= nextBlinkMs_) {
      blinking_ = true;
      blinkStartedMs_ = now;
    }
    if (blinking_ && now - blinkStartedMs_ >= 180) {
      blinking_ = false;
      nextBlinkMs_ = now + 3200 + random(0, 1800);
    }

    float blink = 0.0f;
    if (blinking_) {
      const float phase = (now - blinkStartedMs_) / 180.0f;
      blink = phase < 0.5f ? phase * 2.0f : (1.0f - phase) * 2.0f;
    }
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

  template <typename Display>
  void draw(Display& display, bool attending, float blink) {
    constexpr int kEyeWidth = 86;
    constexpr int kEyeHeight = 112;
    constexpr int kBaseY = 120;
    const int height = max(6, static_cast<int>(kEyeHeight * (1.0f - blink)));
    const int radius = min(30, height / 2);
    const int pupilX = static_cast<int>(lookX_ * 18);
    const int pupilY = static_cast<int>(lookY_ * 12);
    const uint16_t iris = attending ? TFT_CYAN : 0xBDF7;

    display.fillScreen(TFT_BLACK);
    drawEye(display, 102, kBaseY, kEyeWidth, height, radius, pupilX, pupilY,
            iris);
    drawEye(display, 218, kBaseY, kEyeWidth, height, radius, pupilX, pupilY,
            iris);
  }

  template <typename Display>
  void drawEye(Display& display, int centerX, int centerY, int width, int height,
               int radius, int pupilX, int pupilY, uint16_t iris) {
    const int top = centerY - height / 2;
    display.fillRoundRect(centerX - width / 2, top, width, height, radius, iris);
    const int pupilRadius = max(8, min(18, height / 4));
    display.fillCircle(centerX + pupilX, centerY + pupilY, pupilRadius, TFT_BLACK);
    if (height > 24) {
      display.fillCircle(centerX + pupilX - pupilRadius / 3,
                         centerY + pupilY - pupilRadius / 3,
                         max(2, pupilRadius / 5), TFT_WHITE);
    }
  }
};
