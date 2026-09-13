// stanbot: deliberately conservative first hardware slice.
//
// This sketch is built against M5Stack's StackChan-BSP.  It is safe to build
// and inspect before hardware calibration: motor output is disabled by default.

#include <Arduino.h>
#include <M5StackChan.h>

namespace {

// Keep this false until the physical calibration checklist has been completed.
// The BSP powers the servo rail during begin(); setup() immediately disables it
// again when motion is not explicitly armed.
constexpr bool kMotionArmed = false;

// All StackChan BSP angles are tenths of a degree. These are deliberately much
// narrower than the BSP's mechanical limits. They are starting values only and
// must be replaced with measured per-unit limits before kMotionArmed is true.
constexpr int kYawMin = -150;
constexpr int kYawMax = 150;
constexpr int kPitchMin = 50;   // official documentation recommends 5..85 deg
constexpr int kPitchMax = 350;  // avoid the high end until calibrated
constexpr int kRestYaw = 0;
constexpr int kRestPitch = 100;
constexpr uint32_t kControlPeriodMs = 80;
constexpr uint32_t kTargetTimeoutMs = 900;
constexpr float kConfidenceToAttend = 0.70f;

struct FaceObservation {
  bool present = false;
  float confidence = 0.0f;
  // Normalized image coordinates: -1 left/up, +1 right/down.
  float x = 0.0f;
  float y = 0.0f;
  uint32_t capturedAtMs = 0;
};

class LocalFaceSource {
 public:
  void begin() {
    // ESP-WHO integration is intentionally gated behind the ESP-IDF project
    // described in docs/face-detection.md. Do not synthesize observations or
    // treat camera availability as a detected face.
  }

  FaceObservation poll() {
    return {};
  }
};

class SafeHeadController {
 public:
  void begin() {
    M5StackChan.Motion.setAutoTorqueReleaseEnabled(true);
    if (kMotionArmed) {
      M5StackChan.setServoPowerEnabled(true);
      M5StackChan.Motion.setTorqueEnabled(true);
      moveRest();
    } else {
      M5StackChan.Motion.setTorqueEnabled(false);
      M5StackChan.setServoPowerEnabled(false);
    }
  }

  void update(const FaceObservation& observation, uint32_t now) {
    if (!kMotionArmed || now - lastControlMs_ < kControlPeriodMs) return;
    lastControlMs_ = now;

    if (observation.present && observation.confidence >= kConfidenceToAttend) {
      lastTargetMs_ = observation.capturedAtMs;
      // A proportional target is clamped before every servo command. BSP motion
      // supplies interpolation; the command rate is independently bounded here.
      const int yaw = mapNormalized(observation.x, kYawMin, kYawMax);
      const int pitch = mapNormalized(-observation.y, kPitchMin, kPitchMax);
      M5StackChan.Motion.move(yaw, pitch, 180);
      attending_ = true;
      return;
    }

    if (attending_ && now - lastTargetMs_ >= kTargetTimeoutMs) {
      moveRest();
      attending_ = false;
    }
  }

  bool attending() const { return attending_; }

 private:
  uint32_t lastControlMs_ = 0;
  uint32_t lastTargetMs_ = 0;
  bool attending_ = false;

  static int mapNormalized(float value, int minimum, int maximum) {
    value = constrain(value, -1.0f, 1.0f);
    const float fraction = (value + 1.0f) * 0.5f;
    return static_cast<int>(minimum + fraction * (maximum - minimum));
  }

  void moveRest() { M5StackChan.Motion.move(kRestYaw, kRestPitch, 120); }
};

LocalFaceSource faceSource;
SafeHeadController head;
uint32_t lastFrameMs = 0;
bool eyesClosed = false;

void drawAvatar(bool attentive) {
  auto& display = M5StackChan.Display();
  display.fillScreen(TFT_BLACK);
  const uint32_t eye = attentive ? TFT_CYAN : TFT_WHITE;
  if (eyesClosed) {
    display.drawFastHLine(68, 104, 56, eye);
    display.drawFastHLine(196, 104, 56, eye);
  } else {
    display.fillRoundRect(68, 72, 56, 64, 24, eye);
    display.fillRoundRect(196, 72, 56, 64, 24, eye);
    display.fillCircle(96, 104, 13, TFT_BLACK);
    display.fillCircle(224, 104, 13, TFT_BLACK);
  }
  display.drawArc(160, 170, 36, 30, 20, 160, attentive ? TFT_CYAN : TFT_WHITE);
  display.setTextDatum(middle_center);
  display.setTextColor(attentive ? TFT_CYAN : TFT_DARKGREY, TFT_BLACK);
  display.drawString(attentive ? "person detected" : "local / waiting", 160, 222, 2);
  // This is a presence signal only; it does not indicate or claim eye contact.
}

}  // namespace

void setup() {
  M5StackChan.begin();
  M5StackChan.Display().setRotation(1);
  faceSource.begin();
  head.begin();
  drawAvatar(false);
}

void loop() {
  M5StackChan.update();
  const uint32_t now = millis();
  const FaceObservation observation = faceSource.poll();
  head.update(observation, now);

  // Small, deterministic blink animation. It does not depend on networking.
  if (now - lastFrameMs >= 2500) {
    eyesClosed = !eyesClosed;
    drawAvatar(head.attending());
    lastFrameMs = now;
  }
  delay(5);
}
