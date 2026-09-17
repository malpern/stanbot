#pragma once
#include <cstddef>
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

// When the bar should be lit. On as soon as a face is attended to; off only
// after `holdMs` without one, so a missed frame or two does not make it flicker.
struct LightBar {
  static constexpr uint32_t kHoldMs = 1500;
  // A soft blue: this sits on the desk all day, so no glare.
  static constexpr uint8_t kBlueR = 0, kBlueG = 24, kBlueB = 96;

  bool lit = false;
  uint32_t lastFaceMs = 0;
  bool seenFace = false;

  // Returns whether the desired state changed.
  bool update(bool attending, uint32_t nowMs) {
    if (attending) {
      lastFaceMs = nowMs;
      seenFace = true;
    }
    const bool want = seenFace && nowMs - lastFaceMs < kHoldMs;
    if (want == lit) return false;
    lit = want;
    return true;
  }
};

}  // namespace stanbot
