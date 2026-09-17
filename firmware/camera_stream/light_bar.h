#pragma once
#include <cstddef>
#include <cmath>
#include <cstdint>

namespace stanbot {

// The StackChan's light bar: 12 RGB LEDs (0-5 left, 6-11 right), driven by the
// PY32 I/O expander at 0x6F on the camera I2C bus, the same chip whose pin 0
// switches servo motor power. Pure, so companion/test_light_bar.cpp can prove
// the one property that matters: nothing here ever writes a motor-power
// register.
//
// Register map, from StackChan-BSP's PY32IOExpander driver (1.1.0):
//   0x03/0x04 direction L/H   0x05/0x06 output L/H   0x09/0x0A pull-up L/H
//   0x0B/0x0C pull-down L/H   0x13/0x14 drive L/H    0x24 LED config
//   0x30.. LED RAM, two bytes (RGB565, low byte first) per LED
// The LED data line is expander pin 13, bit 5 of the H registers. Motor power
// (VM EN) is pin 0, bit 0 of the L registers, which this never touches.
struct ExpanderWrite { uint8_t reg; uint8_t value; };

constexpr uint8_t kLedPinBit = 1u << (13 - 8);
constexpr uint8_t kRegDirH = 0x04, kRegPullUpH = 0x0A, kRegPullDownH = 0x0C, kRegDriveH = 0x14;
constexpr uint8_t kRegLedConfig = 0x24, kRegLedRam = 0x30;
constexpr uint8_t kLedCount = 12;
constexpr uint8_t kLedRefreshBit = 1u << 6;

// Registers that must never be written from here: motor power's direction,
// output, pulls and drive mode.
constexpr uint8_t kMotorPowerRegisters[] = {0x03, 0x05, 0x09, 0x0B, 0x13};

inline uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b) {
  return static_cast<uint16_t>(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

// The pin-13 setup the BSP performs (output, pull-up, push-pull) and the LED
// count, as writes that change only bit 5 of the H registers read back first.
// Returns how many writes were placed in `out` (5).
inline size_t ledSetupWrites(uint8_t dirH, uint8_t pullUpH, uint8_t pullDownH, uint8_t driveH,
                             ExpanderWrite out[5]) {
  out[0] = {kRegDirH, static_cast<uint8_t>(dirH | kLedPinBit)};
  out[1] = {kRegPullDownH, static_cast<uint8_t>(pullDownH & ~kLedPinBit)};
  out[2] = {kRegPullUpH, static_cast<uint8_t>(pullUpH | kLedPinBit)};
  out[3] = {kRegDriveH, static_cast<uint8_t>(driveH & ~kLedPinBit)};
  out[4] = {kRegLedConfig, kLedCount};
  return 5;
}

// All twelve LEDs one colour, then latch it: 24 RAM writes and the refresh.
// `config` is the LED config register as read back. Returns the count (25).
inline size_t ledColorWrites(uint16_t color565, uint8_t config, ExpanderWrite out[25]) {
  size_t n = 0;
  for (uint8_t i = 0; i < kLedCount; ++i) {
    out[n++] = {static_cast<uint8_t>(kRegLedRam + i * 2), static_cast<uint8_t>(color565 & 0xFF)};
    out[n++] = {static_cast<uint8_t>(kRegLedRam + i * 2 + 1), static_cast<uint8_t>(color565 >> 8)};
  }
  out[n++] = {kRegLedConfig, static_cast<uint8_t>(config | kLedRefreshBit)};
  return n;
}

// All twelve LEDs' colour as one block for the LED RAM, so an update is two
// small I2C transfers (this block, then the refresh) rather than 25. Pulsing
// rewrites it several times a second on the bus the camera and motor power
// share, so the transfer count matters. Returns the byte count (24).
inline size_t ledRamBlock(uint16_t color565, uint8_t out[24]) {
  for (uint8_t i = 0; i < kLedCount; ++i) {
    out[i * 2] = static_cast<uint8_t>(color565 & 0xFF);
    out[i * 2 + 1] = static_cast<uint8_t>(color565 >> 8);
  }
  return static_cast<size_t>(kLedCount) * 2;
}

enum class LightMode { Off, Face, Looking, Lost };

// What the bar shows:
//  - Face: soft blue while a face is attended to, held 1.5 s after the last one
//    so a missed frame does not make it flicker.
//  - Looking: the head is actively looking around for someone (a search or the
//    wake scan). A quick orange pulse, 900 ms per cycle -- the one lively thing
//    the robot does, and it lasts only as long as the hunt.
//  - Lost: the camera is streaming and nobody has been found. Dim, steady
//    purple: waiting, not searching. Never fully off, so it reads as awake.
//  - Off: nobody is watching through the camera. Dark, so it does not glow all
//    night on a desk.
//
// The orange used to be a 5 s breath meaning "streaming, no face", covering
// both of the middle states at once. The owner asked for them apart on
// 2026-09-17: "different colors for looking for you (pulsing orange rapidly),
// and can't find you (dark purple)".
struct LightBar {
  static constexpr uint32_t kHoldMs = 1500;
  static constexpr uint8_t kBlueR = 0, kBlueG = 24, kBlueB = 96;        // desk-friendly
  static constexpr uint8_t kOrangeR = 96, kOrangeG = 32, kOrangeB = 0;  // the pulse's peak
  static constexpr uint8_t kPurpleR = 40, kPurpleG = 0, kPurpleB = 56;  // dim enough to sit next to all evening
  static constexpr uint32_t kPulseMs = 900;                             // a hunting pulse, not a breath
  static constexpr float kPulseFloor = 0.15f;                           // faintest point of the pulse
  // Waking: the bar comes up from dark over this long, orange rising, the
  // moment the robot wakes — before the app has even restarted the camera —
  // so the light reads as waking too. Then the ordinary rules apply.
  static constexpr uint32_t kWakeRampMs = 600;

  LightMode mode = LightMode::Off;
  uint32_t lastFaceMs = 0;
  bool seenFace = false;
  bool waking = false;
  uint32_t wokeMs = 0;

  // The robot has just woken: ramp up from dark.
  void wake(uint32_t nowMs) {
    waking = true;
    wokeMs = nowMs;
  }

  // 0..1 through the wake ramp, 1 once it is over (or never woke).
  float wakeRamp(uint32_t nowMs) const {
    if (!waking) return 1.0f;
    const uint32_t elapsed = nowMs - wokeMs;
    if (elapsed >= kWakeRampMs) return 1.0f;
    const float t = static_cast<float>(elapsed) / kWakeRampMs;
    return t * t * (3.0f - 2.0f * t);   // eased, so it does not snap on at the end
  }

  // `attending`: a face is attended to now. `streaming`: the camera is on.
  // `lookingAround`: the head is sweeping for someone (HeadTracker mode 3).
  // Returns whether the mode changed.
  bool update(bool attending, bool streaming, bool lookingAround, uint32_t nowMs) {
    if (attending) {
      lastFaceMs = nowMs;
      seenFace = true;
    }
    if (waking && nowMs - wokeMs >= kWakeRampMs) waking = false;
    // While waking the bar shows the hunting orange even before the app has
    // restarted the camera, so the light comes up with the eyes -- and a wake
    // is about to start a scan anyway.
    const LightMode want = seenFace && nowMs - lastFaceMs < kHoldMs ? LightMode::Face
                         : (lookingAround || waking) ? LightMode::Looking
                         : streaming ? LightMode::Lost : LightMode::Off;
    if (want == mode) return false;
    mode = want;
    return true;
  }

  // Brightness of the pulse at `nowMs`, kPulseFloor..1, a raised cosine so it
  // eases through both ends instead of turning around sharply.
  static float pulse(uint32_t nowMs) {
    const float phase = static_cast<float>(nowMs % kPulseMs) / kPulseMs;
    const float wave = 0.5f - 0.5f * static_cast<float>(cos(6.2831853 * phase));
    return kPulseFloor + (1.0f - kPulseFloor) * wave;
  }

  uint16_t color(uint32_t nowMs) const {
    const float ramp = wakeRamp(nowMs);
    switch (mode) {
      case LightMode::Face:
        return rgb565(static_cast<uint8_t>(kBlueR * ramp + 0.5f), static_cast<uint8_t>(kBlueG * ramp + 0.5f),
                      static_cast<uint8_t>(kBlueB * ramp + 0.5f));
      case LightMode::Looking: {
        // Through the ramp the pulse is held at its peak, so what rises is
        // the light itself, not a pulse caught at its faintest.
        const float b = (waking ? 1.0f : pulse(nowMs)) * ramp;
        return rgb565(static_cast<uint8_t>(kOrangeR * b + 0.5f), static_cast<uint8_t>(kOrangeG * b + 0.5f),
                      static_cast<uint8_t>(kOrangeB * b + 0.5f));
      }
      case LightMode::Lost:
        return rgb565(static_cast<uint8_t>(kPurpleR * ramp + 0.5f), static_cast<uint8_t>(kPurpleG * ramp + 0.5f),
                      static_cast<uint8_t>(kPurpleB * ramp + 0.5f));
      case LightMode::Off: return 0;
    }
    return 0;
  }
};

}  // namespace stanbot
