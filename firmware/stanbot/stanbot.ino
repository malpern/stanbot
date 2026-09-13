// stanbot: deliberately conservative first hardware slice.
//
// This sketch is built against M5Stack's StackChan-BSP.  It is safe to build
// and inspect before hardware calibration: motor output is disabled by default.

#include <Arduino.h>
#include <M5StackChan.h>
#include "StanbotEyes.h"

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

class UsbTargetSource {
 public:
  void begin() {
    // The mini owns perception. This endpoint accepts a bounded, local USB
    // message only after the mini has analyzed a real camera frame. It cannot
    // command a motor directly.
    Serial.begin(115200);
  }

  FaceObservation poll(uint32_t now) {
    // One line per result: T,<frame-sequence>,<x>,<y>,<confidence>\n
    // x/y must be normalized to [-1, 1]. Values outside the protocol range,
    // stale partial lines, and malformed input are discarded.
    while (Serial.available()) {
      const char byte = static_cast<char>(Serial.read());
      if (byte == '\n') {
        line_[lineLength_] = '\0';
        FaceObservation result{};
        unsigned long sequence = 0;
        if (sscanf(line_, "T,%lu,%f,%f,%f", &sequence, &result.x, &result.y,
                   &result.confidence) == 4 &&
            result.x >= -1.0f && result.x <= 1.0f &&
            result.y >= -1.0f && result.y <= 1.0f &&
            result.confidence >= 0.0f && result.confidence <= 1.0f &&
            sequence > lastSequence_) {
          lastSequence_ = sequence;
          result.present = true;
          result.capturedAtMs = now;
          lineLength_ = 0;
          return result;
        }
        lineLength_ = 0;
      } else if (byte != '\r' && lineLength_ + 1 < sizeof(line_)) {
        line_[lineLength_++] = byte;
      } else {
        lineLength_ = 0;
      }
    }
    return {};
  }

 private:
  char line_[80]{};
  size_t lineLength_ = 0;
  unsigned long lastSequence_ = 0;
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

UsbTargetSource faceSource;
SafeHeadController head;
StanbotEyes eyes;
M5Canvas eyeFrame(&M5StackChan.Display());
bool eyeFrameReady = false;
constexpr uint32_t kBlinkIntervalMs = 3600;
constexpr uint32_t kBlinkDurationMs = 130;
uint32_t blinkStartedMs = 0;
uint32_t nextBlinkMs = 0;
bool eyesClosed = false;

void drawAvatar(bool attentive) {
  auto& display = M5StackChan.Display();
  constexpr uint16_t kPaper = 0xFFFE;
  constexpr uint16_t kInk = 0x18E3;
  constexpr int kStroke = 9;

  display.fillScreen(kPaper);
  // A deliberately original one-bit computer character built from hard pixel
  // blocks. Its proportions and face are specific to Stanbot.
  display.fillRect(52, 10, 216, kStroke, kInk);       // top cap
  display.fillRect(34, 28, kStroke, 178, kInk);       // left case edge
  display.fillRect(277, 28, kStroke, 178, kInk);      // right case edge
  display.fillRect(43, 205, 234, kStroke, kInk);      // case shelf
  display.fillRect(62, 210, 196, 22, kInk);           // base
  display.fillRect(72, 218, 176, 14, kPaper);         // base inset

  // Inset CRT.
  display.fillRect(72, 40, 176, 132, kInk);
  display.fillRect(81, 49, 158, 114, kPaper);

  const uint16_t eye = kInk;
  if (eyesClosed) {
    display.drawFastHLine(110, 104, 28, kInk);
    display.drawFastHLine(182, 104, 28, kInk);
  } else {
    display.fillRect(112, 77, 15, 31, eye);
    display.fillRect(193, 77, 15, 31, eye);
  }
  // Asymmetric nose and square smile: no curves, gradients, or glow.
  display.fillRect(154, 91, 11, 37, kInk);
  display.fillRect(143, 117, 22, 11, kInk);
  display.fillRect(120, 139, 12, 10, kInk);
  display.fillRect(132, 149, 56, 10, kInk);
  display.fillRect(188, 139, 12, 10, kInk);

  // Small local status mark; it changes only after a confidence-qualified
  // observation and is never a claim of eye contact.
  display.fillRect(56, 184, 18, 8, attentive ? kInk : kPaper);
  // This is a presence signal only; it does not indicate or claim eye contact.
}

}  // namespace

void setup() {
  M5StackChan.begin();
  M5StackChan.Display().setRotation(1);
  faceSource.begin();
  head.begin();
  eyeFrame.setColorDepth(16);
  eyeFrameReady = eyeFrame.createSprite(M5StackChan.Display().width(),
                                        M5StackChan.Display().height());
  eyes.begin(millis());
  Serial.println("STANBOT_READY motion=disabled protocol=T,seq,x,y,confidence");
}

void loop() {
  M5StackChan.update();
  const uint32_t now = millis();
  const FaceObservation observation = faceSource.poll(now);
  head.update(observation, now);
  if (observation.present && observation.confidence >= kConfidenceToAttend) {
    eyes.attend(observation.x, observation.y, now);
  }
  if (eyeFrameReady) {
    if (eyes.update(eyeFrame, now)) eyeFrame.pushSprite(0, 0);
  } else {
    // Safe fallback if a frame buffer cannot be allocated.
    eyes.update(M5StackChan.Display(), now);
  }
  delay(5);
}
