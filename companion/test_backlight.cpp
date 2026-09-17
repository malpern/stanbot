#include "../firmware/camera_stream/backlight.h"
#include <cassert>
#include <cstdio>

using namespace stanbot;

int main() {
  AxpWrite writes[2];

  // Off: DLDO1 disabled and its voltage zeroed, whatever else 0x90 holds.
  for (unsigned now = 0; now < 256; ++now) {
    assert(backlightWrites(0, static_cast<uint8_t>(now), writes) == 2);
    assert(writes[0].reg == kAxpLdoControl);
    assert((writes[0].value & kAxpDldo1Bit) == 0);
    assert((writes[0].value & ~kAxpDldo1Bit) == (now & ~kAxpDldo1Bit));   // the other rails untouched
    assert(writes[1].reg == kAxpDldo1Voltage && writes[1].value == 0);
  }

  // On: DLDO1 enabled, the other rails untouched, the level M5GFX would set.
  for (unsigned now = 0; now < 256; ++now) {
    backlightWrites(255, static_cast<uint8_t>(now), writes);
    assert((writes[0].value & kAxpDldo1Bit) != 0);
    assert((writes[0].value & ~kAxpDldo1Bit) == (now & ~kAxpDldo1Bit));
  }
  backlightWrites(255, 0, writes);
  assert(writes[1].value == ((255 + 641) >> 5));   // 28, as Light_M5StackCoreS3
  backlightWrites(1, 0, writes);
  assert(writes[1].value == ((1 + 641) >> 5));     // 20: dim but lit
  // Brighter never means a lower level.
  uint8_t last = 0;
  for (unsigned b = 1; b < 256; ++b) {
    backlightWrites(static_cast<uint8_t>(b), 0, writes);
    assert(writes[1].value >= last);
    last = writes[1].value;
  }

  std::puts("backlight: all checks passed");
  return 0;
}
