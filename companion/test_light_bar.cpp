// c++ -std=c++17 companion/test_light_bar.cpp -o /tmp/test_light_bar && /tmp/test_light_bar
#include "../firmware/camera_stream/light_bar.h"
#include <cassert>
#include <cstdio>

using namespace stanbot;

static bool touchesMotorPower(const ExpanderWrite* writes, size_t count) {
  for (size_t i = 0; i < count; ++i)
    for (uint8_t reg : kMotorPowerRegisters)
      if (writes[i].reg == reg) return true;
  return false;
}

int main() {
  // Setup changes only bit 5 (pin 13) of the H registers, whatever they held.
  for (unsigned seed = 0; seed < 256; ++seed) {
    const uint8_t dir = seed, pu = seed ^ 0xA5, pd = seed ^ 0x5A, drv = ~seed;
    ExpanderWrite setup[5];
    const size_t n = ledSetupWrites(dir, pu, pd, drv, setup);
    assert(n == 5);
    assert(!touchesMotorPower(setup, n));
    assert((setup[0].value & ~kLedPinBit) == (dir & ~kLedPinBit) && (setup[0].value & kLedPinBit));
    assert((setup[1].value & ~kLedPinBit) == (pd & ~kLedPinBit) && !(setup[1].value & kLedPinBit));
    assert((setup[2].value & ~kLedPinBit) == (pu & ~kLedPinBit) && (setup[2].value & kLedPinBit));
    assert((setup[3].value & ~kLedPinBit) == (drv & ~kLedPinBit) && !(setup[3].value & kLedPinBit));
    assert(setup[4].reg == kRegLedConfig && setup[4].value == kLedCount);
  }
  // Colour: 12 LEDs x 2 bytes in the LED RAM, then the refresh bit, nothing else.
  ExpanderWrite color[25];
  const uint16_t blue = rgb565(LightBar::kBlueR, LightBar::kBlueG, LightBar::kBlueB);
  const size_t n = ledColorWrites(blue, 0x0C, color);
  assert(n == 25);
  assert(!touchesMotorPower(color, n));
  for (size_t i = 0; i < 24; ++i) assert(color[i].reg >= kRegLedRam && color[i].reg < kRegLedRam + 24);
  assert(color[0].value == (blue & 0xFF) && color[1].value == (blue >> 8));
  assert(color[24].reg == kRegLedConfig && color[24].value == (0x0C | kLedRefreshBit));
  // The same conversion the BSP uses.
  assert(rgb565(255, 255, 255) == 0xFFFF && rgb565(0, 0, 0) == 0 && rgb565(0, 0, 255) == 0x001F);

  // Lit while attending; stays lit through a short gap; off after the hold.
  LightBar bar;
  assert(!bar.update(false, 1000) && !bar.lit);          // nothing seen yet: stays off
  assert(bar.update(true, 2000) && bar.lit);
  assert(!bar.update(false, 2000 + 800) && bar.lit);     // a missed frame or two
  assert(!bar.update(true, 3000) && bar.lit);
  assert(!bar.update(false, 3000 + LightBar::kHoldMs - 1) && bar.lit);
  assert(bar.update(false, 3000 + LightBar::kHoldMs) && !bar.lit);
  assert(bar.update(true, 9000) && bar.lit);             // and back on
  std::puts("light bar: all checks passed");
}
