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

  // The block write: 24 bytes of LED RAM, one colour, starting at 0x30 and
  // ending before 0x48, far from every motor-power register.
  uint8_t block[24];
  assert(ledRamBlock(blue, block) == 24);
  for (int i = 0; i < 24; i += 2) assert(block[i] == (blue & 0xFF) && block[i + 1] == (blue >> 8));
  for (uint8_t reg : kMotorPowerRegisters) assert(reg < kRegLedRam || reg >= kRegLedRam + 24);

  // Modes: dark while nobody watches, orange while looking, blue with a face.
  LightBar bar;
  assert(!bar.update(false, false, 1000) && bar.mode == LightMode::Off && bar.color(1000) == 0);
  assert(bar.update(false, true, 1100) && bar.mode == LightMode::Searching);
  assert(bar.update(true, true, 2000) && bar.mode == LightMode::Face);
  assert(bar.color(2000) == blue);
  assert(!bar.update(false, true, 2000 + 800) && bar.mode == LightMode::Face);   // a missed frame or two
  assert(!bar.update(true, true, 3000));
  assert(!bar.update(false, true, 3000 + LightBar::kHoldMs - 1) && bar.mode == LightMode::Face);
  assert(bar.update(false, true, 3000 + LightBar::kHoldMs) && bar.mode == LightMode::Searching);
  assert(bar.update(false, false, 9000) && bar.mode == LightMode::Off);        // the app stopped watching

  // The breath: gentle, never off, never brighter than the peak, and smooth
  // enough that eight updates a second show no visible steps.
  float lowest = 1, highest = 0, biggestStep = 0, last = LightBar::breath(0);
  for (uint32_t t = 0; t <= 2 * LightBar::kBreathMs; t += 125) {
    const float b = LightBar::breath(t);
    lowest = b < lowest ? b : lowest;
    highest = b > highest ? b : highest;
    const float step = b > last ? b - last : last - b;
    biggestStep = step > biggestStep ? step : biggestStep;
    last = b;
  }
  std::printf("  breath: %.2f..%.2f, largest step per 125 ms %.3f\n", lowest, highest, biggestStep);
  assert(lowest >= LightBar::kBreathFloor - 0.001f && highest <= 1.001f);
  assert(highest > 0.95f && lowest < LightBar::kBreathFloor + 0.05f);
  assert(biggestStep < 0.1f);
  // Eased at the ends: the change near the peak is small.
  assert(LightBar::breath(LightBar::kBreathMs / 2 + 125) > 0.98f);
  // Orange at its peak is the dim orange, and it never exceeds it.
  bar.update(false, true, 20000);
  uint16_t peak = 0;
  for (uint32_t t = 0; t < LightBar::kBreathMs; t += 50) {
    const uint16_t c = bar.color(t);
    assert(((c >> 11) & 0x1F) <= (LightBar::kOrangeR >> 3));
    if (c > peak) peak = c;
  }
  assert(peak == rgb565(LightBar::kOrangeR, LightBar::kOrangeG, LightBar::kOrangeB));
  // Waking: from dark, orange rising over the ramp even before the camera is
  // back, eased, reaching the full orange, then the ordinary rules again.
  LightBar woke;
  woke.update(false, false, 30000);
  assert(woke.mode == LightMode::Off && woke.color(30000) == 0);
  woke.wake(30000);
  assert(woke.update(false, false, 30000) && woke.mode == LightMode::Searching);   // no stream yet, still lit
  assert(woke.color(30000) == 0);                                                   // but from dark
  const uint16_t quarter = woke.color(30000 + LightBar::kWakeRampMs / 4);
  const uint16_t half = woke.color(30000 + LightBar::kWakeRampMs / 2);
  const uint16_t full = woke.color(30000 + LightBar::kWakeRampMs);
  assert(((quarter >> 11) & 0x1F) < ((half >> 11) & 0x1F));                        // rising
  assert(((half >> 11) & 0x1F) < ((full >> 11) & 0x1F));
  assert(full == rgb565(LightBar::kOrangeR, LightBar::kOrangeG, LightBar::kOrangeB));   // all the way up
  // Ramp over and the app still has not restarted the camera: dark again, as the rules say.
  assert(woke.update(false, false, 30000 + LightBar::kWakeRampMs) && woke.mode == LightMode::Off);
  // With the camera back it breathes as usual; a face during the ramp comes up blue.
  LightBar faced;
  faced.wake(40000);
  faced.update(true, true, 40000);
  assert(faced.mode == LightMode::Face && faced.color(40000) == 0);
  assert(faced.color(40000 + LightBar::kWakeRampMs) == blue);

  std::puts("light bar: all checks passed");
}
