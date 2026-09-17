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

enum class LightMode { Off, Face, Searching };

// What the bar shows:
//  - Face: soft blue while a face is attended to, held 1.5 s after the last one
//    so a missed frame does not make it flicker.
//  - Searching: the camera is streaming to the app and no face is in view. A
//    very gentle orange breath, 5 s per cycle, between a faint glow and a dim
//    orange. Never fully off, so it reads as waiting, not blinking.
//  - Off: nobody is watching through the camera. Dark, so it does not pulse all
//    night on a desk.
struct LightBar {
  static constexpr uint32_t kHoldMs = 1500;
  static constexpr uint8_t kBlueR = 0, kBlueG = 24, kBlueB = 96;       // desk-friendly
  static constexpr uint8_t kOrangeR = 96, kOrangeG = 32, kOrangeB = 0;  // the breath's peak
  static constexpr uint32_t kBreathMs = 5000;
  static constexpr float kBreathFloor = 0.2f;                           // faintest point of the breath

  LightMode mode = LightMode::Off;
  uint32_t lastFaceMs = 0;
  bool seenFace = false;

  // `attending`: a face is attended to now. `looking`: the camera is streaming.
  // Returns whether the mode changed.
  bool update(bool attending, bool looking, uint32_t nowMs) {
    if (attending) {
      lastFaceMs = nowMs;
      seenFace = true;
    }
    const LightMode want = seenFace && nowMs - lastFaceMs < kHoldMs ? LightMode::Face
                         : looking ? LightMode::Searching : LightMode::Off;
    if (want == mode) return false;
    mode = want;
    return true;
  }

  // Brightness of the breath at `nowMs`, kBreathFloor..1, a raised cosine so it
  // eases through both ends instead of turning around sharply.
  static float breath(uint32_t nowMs) {
    const float phase = static_cast<float>(nowMs % kBreathMs) / kBreathMs;
    const float wave = 0.5f - 0.5f * static_cast<float>(cos(6.2831853 * phase));
    return kBreathFloor + (1.0f - kBreathFloor) * wave;
  }

  uint16_t color(uint32_t nowMs) const {
    switch (mode) {
      case LightMode::Face: return rgb565(kBlueR, kBlueG, kBlueB);
      case LightMode::Searching: {
        const float b = breath(nowMs);
        return rgb565(static_cast<uint8_t>(kOrangeR * b + 0.5f), static_cast<uint8_t>(kOrangeG * b + 0.5f),
                      static_cast<uint8_t>(kOrangeB * b + 0.5f));
      }
      case LightMode::Off: return 0;
    }
    return 0;
  }
};

}  // namespace stanbot
