// c++ -std=c++17 companion/test_frame_pacer.cpp -o /tmp/test_frame_pacer && /tmp/test_frame_pacer
#include "../firmware/camera_stream/frame_pacer.h"
#include <cassert>
#include <cmath>
#include <cstdio>

// Feed a sensor that delivers a frame every `periodMs` (with small jitter) for a
// minute and return the send rate in frames per second.
static double rate(uint32_t intervalMs, double periodMs, uint32_t startMs = 4000000000u) {
  stanbot::FramePacer pacer;
  int sent = 0;
  const double seconds = 60;
  const int frames = static_cast<int>(seconds * 1000 / periodMs);
  for (int i = 0; i < frames; ++i) {
    const uint32_t now = startMs + static_cast<uint32_t>(i * periodMs + ((i * 7) % 5) - 2);
    if (pacer.due(now, intervalMs)) { pacer.sent(now, intervalMs); ++sent; }
  }
  return sent / seconds;
}

int main() {
  const double sensor = 192.0;             // ~5.2 fps, measured on this unit
  const double ceiling = 1000.0 / sensor;
  // The regression: 200 ms must not halve the rate.
  double r200 = rate(200, sensor);
  assert(r200 > 4.8 && r200 <= ceiling + 0.01);
  // Faster than the sensor: every frame.
  assert(std::fabs(rate(100, sensor) - ceiling) < 0.05);
  // Slower requests average close to what was asked.
  assert(std::fabs(rate(333, sensor) - 3.0) < 0.2);
  assert(std::fabs(rate(750, sensor) - 1.333) < 0.1);
  // A slow encoder (frames dequeued every ~290 ms) still sends every frame at 200.
  assert(std::fabs(rate(200, 290.0) - 1000.0 / 290.0) < 0.05);
  // millis() wrapping mid-run changes nothing (start just below 2^32).
  assert(std::fabs(rate(200, sensor, 4294960000u) - r200) < 0.1);
  // A stall does not produce a burst: after a 2 s gap, the next two frames
  // are not both sent.
  stanbot::FramePacer pacer;
  pacer.sent(0, 200);
  assert(pacer.due(2000, 200));
  pacer.sent(2000, 200);
  assert(!pacer.due(2010, 200));
  std::printf("frame pacer: 200 ms -> %.2f fps, 333 -> %.2f, 750 -> %.2f, 100 -> %.2f; all checks passed\n",
              r200, rate(333, sensor), rate(750, sensor), rate(100, sensor));
}
