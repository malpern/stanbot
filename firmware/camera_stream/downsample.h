#pragma once
#include <cstdint>

// Box-average a 640x480 YUYV frame down to 320x240 YUYV.
//
// Pure and header-only so the host tests can exercise it without hardware.
// YUYV packs two pixels per four bytes as Y0 U Y1 V, so two output pixels are
// produced from a 4x2 block of source pixels: eight luma samples and four
// chroma pairs, every one of which contributes.
//
// The earlier implementation point-sampled (one source pixel in four, both
// chroma samples from the first pair only), which aliased edges and passed
// sensor noise straight through into the encoder.
inline void boxAverageYuyvHalf(const uint8_t* source, uint8_t* destination) {
  for (unsigned y = 0; y < 240; ++y) {
    const uint8_t* row0 = source + (y * 2) * 640 * 2;
    const uint8_t* row1 = row0 + 640 * 2;
    uint8_t* out = destination + y * 320 * 2;
    for (unsigned x = 0; x < 160; ++x) {
      // Sums of four bytes fit a uint16_t; +2 rounds to nearest, not down.
      out[0] = static_cast<uint8_t>((row0[0] + row0[2] + row1[0] + row1[2] + 2) >> 2);
      out[2] = static_cast<uint8_t>((row0[4] + row0[6] + row1[4] + row1[6] + 2) >> 2);
      out[1] = static_cast<uint8_t>((row0[1] + row0[5] + row1[1] + row1[5] + 2) >> 2);
      out[3] = static_cast<uint8_t>((row0[3] + row0[7] + row1[3] + row1[7] + 2) >> 2);
      row0 += 8; row1 += 8; out += 4;
    }
  }
}
