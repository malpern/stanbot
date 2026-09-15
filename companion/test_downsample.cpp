// Native correctness test for the QVGA box-average downsample.
// Build and run (bounds are checked by the sanitizer, so keep it on):
//   c++ -std=c++17 -O1 -fsanitize=address,undefined -Wall -Wextra \
//       companion/test_downsample.cpp -o /tmp/td && /tmp/td
#include "../firmware/camera_stream/downsample.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

// Independent reference: average the 2x2 luma block and the 2x2 chroma pairs.
// Written from the YUYV definition rather than from the implementation.
void reference(const uint8_t* src, uint8_t* dst) {
  auto at = [&](unsigned x, unsigned y) { return src + (y * 640 + x) * 2; };
  for (unsigned oy = 0; oy < 240; ++oy)
    for (unsigned ox = 0; ox < 320; ++ox) {
      unsigned sx = ox * 2, sy = oy * 2;
      unsigned luma = at(sx, sy)[0] + at(sx + 1, sy)[0] + at(sx, sy + 1)[0] + at(sx + 1, sy + 1)[0];
      dst[(oy * 320 + ox) * 2] = static_cast<uint8_t>((luma + 2) >> 2);
      if (ox % 2) continue;                       // chroma is shared by a pair
      unsigned u = 0, v = 0;
      for (unsigned dy = 0; dy < 2; ++dy)
        for (unsigned px = 0; px < 2; ++px) {     // two source pairs per output pair
          const uint8_t* pair = at(sx + px * 2, sy + dy);
          u += pair[1];
          v += pair[3];
        }
      dst[(oy * 320 + ox) * 2 + 1] = static_cast<uint8_t>((u + 2) >> 2);
      dst[(oy * 320 + ox) * 2 + 3] = static_cast<uint8_t>((v + 2) >> 2);
    }
}

std::vector<uint8_t> frame(unsigned seed) {
  std::vector<uint8_t> data(640 * 480 * 2);
  unsigned state = seed;
  for (auto& byte : data) { state = state * 1103515245u + 12345u; byte = (state >> 16) & 0xff; }
  return data;
}

}  // namespace

int main() {
  // 1. Matches an independently written reference on pseudorandom frames.
  for (unsigned seed : {1u, 7u, 99u}) {
    auto src = frame(seed);
    std::vector<uint8_t> got(320 * 240 * 2), want(320 * 240 * 2);
    boxAverageYuyvHalf(src.data(), got.data());
    reference(src.data(), want.data());
    assert(got == want);
  }

  // 2. A flat frame must survive exactly: no rounding drift anywhere.
  {
    std::vector<uint8_t> src(640 * 480 * 2);
    for (size_t i = 0; i < src.size(); i += 4) { src[i] = 200; src[i + 1] = 90; src[i + 2] = 200; src[i + 3] = 160; }
    std::vector<uint8_t> got(320 * 240 * 2);
    boxAverageYuyvHalf(src.data(), got.data());
    for (size_t i = 0; i < got.size(); i += 4)
      assert(got[i] == 200 && got[i + 1] == 90 && got[i + 2] == 200 && got[i + 3] == 160);
  }

  // 3. The point THIS change exists for: a one-pixel-checkerboard frame is pure
  //    aliasing energy. Averaging resolves it to the mean; point sampling would
  //    return one extreme or the other and alias it into the output.
  {
    std::vector<uint8_t> src(640 * 480 * 2);
    for (unsigned y = 0; y < 480; ++y)
      for (unsigned x = 0; x < 640; ++x) {
        uint8_t* pixel = src.data() + (y * 640 + x) * 2;
        pixel[0] = ((x + y) % 2) ? 255 : 0;
        pixel[1] = 128;
      }
    std::vector<uint8_t> got(320 * 240 * 2);
    boxAverageYuyvHalf(src.data(), got.data());
    for (size_t i = 0; i < got.size(); i += 2)
      assert(got[i] == 128);  // (0+255+255+0+2)/4, the true local mean
  }

  // 4. Bounds are proven by running this binary under AddressSanitizer, which
  //    checks every access against the exact allocation sizes above. Hand-written
  //    index arithmetic here would only restate the implementation.

  printf("downsample: checks passed\n");
  return 0;
}
