#pragma once
// Integrity check for a telemetry block (SBTB ... SBTE). Pure, so it is tested
// natively by companion/test_telemetry_check.cpp; the app and sbstream.py
// compute the same thing.
//
// Session 2 (2026-09-16) lost one byte on USB: the result line arrived as
// "yaw_fnal", still valid-looking JSON with a wrong key. Nothing flagged it.
// Now SBTE carries the number of lines and a CRC-32 (IEEE, as zlib) over the
// bytes of every line in the block with line terminators removed ('\r' and
// '\n' are not hashed; each '\n' counts a line). A lost, changed or added byte
// changes the CRC; a lost newline changes the count.
#include <cstddef>
#include <cstdint>

namespace stanbot {

inline uint32_t crc32Update(uint32_t crc, uint8_t byte) {
  crc ^= byte;
  for (int bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
  return crc;
}

struct TelemetryCheck {
  uint32_t crc = 0xFFFFFFFFu;
  uint32_t lines = 0;

  void add(const uint8_t* data, size_t size) {
    for (size_t i = 0; i < size; ++i) {
      if (data[i] == '\n') ++lines;
      else if (data[i] != '\r') crc = crc32Update(crc, data[i]);
    }
  }
  uint32_t value() const { return crc ^ 0xFFFFFFFFu; }
};

}  // namespace stanbot
