#include "../firmware/camera_stream/telemetry_check.h"
#include <cassert>
#include <cstdio>
#include <cstring>

using stanbot::TelemetryCheck;

static TelemetryCheck of(const char* text) {
  TelemetryCheck check;
  check.add(reinterpret_cast<const uint8_t*>(text), std::strlen(text));
  return check;
}

int main() {
  // The standard CRC-32 check value.
  assert(of("123456789").value() == 0xCBF43926u);
  assert(of("").value() == 0 && of("").lines == 0);
  // Terminators are not hashed, but newlines are counted.
  assert(of("SBMV {\"a\":1}\nSBFL {}\n").value() == of("SBMV {\"a\":1}\r\nSBFL {}\r\n").value());
  assert(of("SBMV {\"a\":1}\nSBFL {}\n").lines == 2);
  // Chunking does not matter.
  TelemetryCheck split;
  split.add(reinterpret_cast<const uint8_t*>("SBMV {\"yaw_"), 11);
  split.add(reinterpret_cast<const uint8_t*>("final\":1}\n"), 10);
  assert(split.value() == of("SBMV {\"yaw_final\":1}\n").value());
  // Session 2's lost byte is caught; so is a lost newline.
  assert(of("SBMV {\"yaw_fnal\":1}\n").value() != of("SBMV {\"yaw_final\":1}\n").value());
  assert(of("A\nB\n").lines != of("AB\n").lines);
  // Shared vector with the Swift and Python implementations.
  const TelemetryCheck shared = of("SBMV {\"result\":\"session_idle\"}\nSBFL {\"renewals\":3}\n");
  std::printf("telemetry check: shared vector lines=%u crc=%08x\n", shared.lines, shared.value());
  assert(shared.lines == 2);
  std::printf("telemetry check: all tests passed\n");
}
