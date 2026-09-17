#include "../firmware/camera_stream/head_eye.h"
#include <cassert>
#include <cmath>
#include <cstdio>

using namespace stanbot;

namespace {
const FollowLimits kLimits = {460 - 144, 460 + 144, 460, 596, 700, 620, +1, true, 64, 24, false};

// Closed loop: a face fixed in the world, frames every 200 ms arriving 300 ms
// late, the tracker turning the head toward it. Each tick, where do the eyes
// point in the world, with and without correcting for the head's motion?
struct Result { double worstError; double meanError; };

Result run(bool compensate) {
  FollowConfig config;
  HeadTracker tracker(kLimits, config);
  uint32_t now = 100000;
  int head = 460;
  tracker.begin(head, 640, now);
  const double faceWorld = 460 + 90;            // raw yaw at which the head would face the person
  struct Frame { uint32_t sentMs; int headThen; uint32_t seq; };
  Frame q[8]{};
  unsigned queued = 0;
  uint32_t nextFrame = now, seq = 0;
  float eyeX = 0;                                // eye target, image units
  bool haveEye = false;
  uint32_t lastSent = now;
  int headThen = head;
  double worst = 0, sum = 0;
  int samples = 0;
  for (int tick = 0; tick < 250; ++tick) {
    now += config.controlPeriodMs;
    if (static_cast<int32_t>(now - nextFrame) >= 0) {
      nextFrame = now + 200;
      if (queued < 8) q[queued++] = {now, head, ++seq};
    }
    if (queued > 0 && static_cast<int32_t>(now - q[0].sentMs) >= 300) {
      const Frame f = q[0];
      for (unsigned i = 1; i < queued; ++i) q[i - 1] = q[i];
      --queued;
      const float x = static_cast<float>((faceWorld - f.headThen) / config.rawPerUnitX);
      tracker.observe(f.seq, x, 0.0f, 0.95f, now, f.sentMs);
      eyeX = x;
      lastSent = f.sentMs;
      headThen = tracker.yawAt(f.sentMs);
      haveEye = true;
    }
    const FollowCommand command = tracker.step(now);
    if (command.send) head = command.yaw;
    if (!haveEye || tick < 10) continue;
    const float aim = compensate
        ? compensateForHead(eyeX, 0, headThen, tracker.commandedYaw(), 640, 640, kLimits, config).x
        : eyeX;
    (void)lastSent;
    // Where the eyes point in the world, in raw yaw units.
    const double eyeWorld = head + aim * config.rawPerUnitX;
    const double error = std::fabs(eyeWorld - faceWorld);
    worst = error > worst ? error : worst;
    sum += error;
    ++samples;
  }
  return {worst, sum / samples};
}
}  // namespace

int main() {
  // Units and signs.
  FollowConfig config;
  // Head turned right by a whole rawPerUnitX: a face at +0.5 is now at -0.5.
  ImageOffset o = compensateForHead(0.5f, 0.0f, 460, 460 + config.rawPerUnitX, 640, 640, kLimits, config);
  assert(std::fabs(o.x + 0.5f) < 1e-4 && o.y == 0.0f);
  // Tilted up by rawPerUnitY: a face at the centre is now lower in the image.
  o = compensateForHead(0.0f, 0.0f, 460, 460, 640, 640 + config.rawPerUnitY, kLimits, config);
  assert(std::fabs(o.y - 1.0f) < 1e-4);
  // No motion, no change; and always clamped to the image.
  o = compensateForHead(0.3f, -0.2f, 500, 500, 650, 650, kLimits, config);
  assert(o.x == 0.3f && o.y == -0.2f);
  o = compensateForHead(-0.9f, 0.9f, 460, 460 + 300, 640, 640 + 300, kLimits, config);
  assert(o.x == -1.0f && o.y == 1.0f);

  // Large shifts only.
  assert(!largeGazeShift(460, 460 + 20, 640, 640 + 20));
  assert(largeGazeShift(460, 460 + 48, 640, 640));
  assert(largeGazeShift(460, 460 + 40, 640, 640 + 30));

  // In the loop, the corrected gaze stays on the person while the head turns.
  const Result plain = run(false), corrected = run(true);
  std::printf("  gaze error while turning, raw yaw units: uncorrected worst %.1f mean %.1f; corrected worst %.1f mean %.1f\n",
              plain.worstError, plain.meanError, corrected.worstError, corrected.meanError);
  assert(corrected.worstError < plain.worstError * 0.6);
  assert(corrected.meanError < plain.meanError * 0.6);
  assert(corrected.worstError <= 16);   // within the envelope margin: about 5 degrees
  std::printf("head eye: all tests passed\n");
}
