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
constexpr uint32_t kBlinkIntervalMs = 3600;
constexpr uint32_t kBlinkDurationMs = 130;
uint32_t blinkStartedMs = 0;
uint32_t nextBlinkMs = 0;
bool eyesClosed = false;

void drawAvatar(bool attentive) {
  auto& display = M5StackChan.Display();
  constexpr uint16_t kCaseBeige = 0xD5B7;
  constexpr uint16_t kCaseShadow = 0x9C71;
  constexpr uint16_t kCrt = 0x18E3;
  constexpr uint16_t kPhosphor = 0xEF5D;
  constexpr uint16_t kFeature = 0x2945;

  display.fillScreen(TFT_BLACK);
  // An original compact-computer character: its warm enclosure and inset CRT
  // nod to early Macs without reproducing Apple's historic face artwork.
  display.fillRoundRect(44, 14, 232, 212, 22, kCaseBeige);
  display.drawRoundRect(44, 14, 232, 212, 22, kCaseShadow);
  display.fillRoundRect(66, 42, 184, 132, 12, kCrt);
  display.drawRoundRect(66, 42, 184, 132, 12, kCaseShadow);

  const uint16_t eye = attentive ? TFT_CYAN : kPhosphor;
  if (eyesClosed) {
    display.drawFastHLine(98, 108, 40, eye);
    display.drawFastHLine(182, 108, 40, eye);
  } else {
    display.fillRoundRect(102, 80, 32, 50, 12, eye);
    display.fillRoundRect(186, 80, 32, 50, 12, eye);
    display.fillCircle(118, 105, 8, kCrt);
    display.fillCircle(202, 105, 8, kCrt);
  }
  // A deliberately plain mouth line, with no bright anti-aliased glow.
  display.drawFastHLine(136, 143, 48, kFeature);

  // Speaker grille and a single local attention indicator.
  for (int y = 68; y <= 150; y += 10) {
    display.drawFastHLine(244, y, 14, kCaseShadow);
  }
  display.fillCircle(160, 196, 5, attentive ? TFT_CYAN : kCaseShadow);
  // This is a presence signal only; it does not indicate or claim eye contact.
}

}  // namespace

void setup() {
  M5StackChan.begin();
  M5StackChan.Display().setRotation(1);
  faceSource.begin();
  head.begin();
  drawAvatar(false);
  nextBlinkMs = millis() + kBlinkIntervalMs;
  Serial.println("STANBOT_READY motion=disabled protocol=T,seq,x,y,confidence");
}

void loop() {
  M5StackChan.update();
  const uint32_t now = millis();
  const FaceObservation observation = faceSource.poll(now);
  head.update(observation, now);

  // A short, deterministic blink. It does not depend on networking.
  if (!eyesClosed && now >= nextBlinkMs) {
    eyesClosed = true;
    blinkStartedMs = now;
    drawAvatar(head.attending());
  } else if (eyesClosed && now - blinkStartedMs >= kBlinkDurationMs) {
    eyesClosed = false;
    nextBlinkMs = now + kBlinkIntervalMs;
    drawAvatar(head.attending());
  }
  delay(5);
}
