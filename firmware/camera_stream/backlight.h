#pragma once

// The CoreS3's screen backlight, for sleep and wake. It is the AXP2101's DLDO1
// rail, on the internal I2C bus.
//
// Do NOT use M5.Display.setBrightness for this. It reaches the same chip with
// M5GFX's own I2C driver, on the bus the camera task drives with i2c_master.
// Two drivers on one port leave it in ESP_ERR_INVALID_STATE (259): after the
// first sleep every transaction to the base failed, so motor power could not be
// switched and the light bar could not be written. Head following and the light
// bar were dead from the first sleep until the next reboot, and nothing said so
// (2026-09-17). These are the same two register writes M5GFX makes
// (Light_M5StackCoreS3), sent through the camera task's driver instead.
//
// Plain C++, so companion/test_backlight.cpp runs it on the Mac.

#include <cstddef>
#include <cstdint>

namespace stanbot {

constexpr uint8_t kAxpAddress = 0x34;
constexpr uint8_t kAxpLdoControl = 0x90;    // LDO on/off; bit 7 is DLDO1, the backlight
constexpr uint8_t kAxpDldo1Voltage = 0x99;  // DLDO1 voltage: the brightness
constexpr uint8_t kAxpDldo1Bit = 0x80;

struct AxpWrite { uint8_t reg; uint8_t value; };

// The writes for a brightness of 0 (off) to 255, given what 0x90 holds now.
// Only bit 7 of 0x90 changes: the other rails it controls are left alone.
inline size_t backlightWrites(uint8_t brightness, uint8_t ldoControlNow, AxpWrite out[2]) {
  if (brightness != 0) {
    out[0] = {kAxpLdoControl, static_cast<uint8_t>(ldoControlNow | kAxpDldo1Bit)};
    out[1] = {kAxpDldo1Voltage, static_cast<uint8_t>((brightness + 641) >> 5)};
  } else {
    out[0] = {kAxpLdoControl, static_cast<uint8_t>(ldoControlNow & ~kAxpDldo1Bit)};
    out[1] = {kAxpDldo1Voltage, 0};
  }
  return 2;
}

}  // namespace stanbot
