#include "../firmware/lib/StanbotEyes/src/GazeBrain.h"
#include <cassert>
#include <cmath>
#include <cstdio>

using stanbot::GazeBrain;

static float distance(const GazeBrain& b, float x, float y) { return std::hypot(b.lookX - x, b.lookY - y); }

int main() {
  // Nobody engaging, a face right in the middle: the eyes mostly look away.
  {
    GazeBrain brain(1234);
    int near = 0, total = 0;
    for (uint32_t t = 0; t < 60000; t += 33) {
      brain.update(t, true, 0.0f, 0.0f, false);
      if (t > 1000) { ++total; if (distance(brain, 0, 0) < 0.2f) ++near; }
      assert(brain.dilation < 1.01f);
    }
    std::printf("  not engaged: looking at the face %.0f%% of the time\n", 100.0 * near / total);
    assert(near * 100 < total * 30);   // under 30%: occasional shy glances, not a stare
    assert(near > 0);                  // but it does glance
  }
  // Nobody at all: wanders, and rarely rests on the middle of the view.
  {
    GazeBrain brain(99);
    int middle = 0, total = 0;
    float minX = 1, maxX = -1;
    for (uint32_t t = 0; t < 60000; t += 33) {
      brain.update(t, false, 0, 0, false);
      if (t > 1000) {
        ++total;
        if (std::fabs(brain.lookX) < 0.15f) ++middle;
        minX = brain.lookX < minX ? brain.lookX : minX;
        maxX = brain.lookX > maxX ? brain.lookX : maxX;
      }
    }
    std::printf("  nobody: middle %.0f%%, x range %.2f..%.2f\n", 100.0 * middle / total, minX, maxX);
    assert(middle * 100 < total * 15);
    assert(minX < -0.5f && maxX > 0.5f);
  }
  // Engaged: locks on within half a second, follows a moving face, pupils dilate.
  {
    GazeBrain brain(7);
    uint32_t t = 0;
    for (; t < 2000; t += 33) brain.update(t, true, -0.5f, 0.3f, false);
    const uint32_t engagedAt = t;
    for (; t < engagedAt + 500; t += 33) brain.update(t, true, 0.4f, -0.2f, true);
    assert(distance(brain, 0.4f, -0.2f) < 0.08f);
    for (; t < engagedAt + 700; t += 33) brain.update(t, true, 0.4f, -0.2f, true);
    assert(brain.dilation > 1.3f);
    // Follows as the face moves.
    float x = 0.4f;
    for (int i = 0; i < 60; ++i, t += 33) {
      x -= 0.01f;
      brain.update(t, true, x, -0.2f, true);
      if (i > 10) assert(distance(brain, x, -0.2f) < 0.12f);
    }
    // Turns away: pupils relax, more slowly than they widened.
    uint32_t awayAt = t;
    brain.update(t, true, x, -0.2f, false);
    for (t += 33; t < awayAt + 200; t += 33) brain.update(t, true, x, -0.2f, false);
    assert(brain.dilation > 1.15f);           // still relaxing after 200 ms
    for (; t < awayAt + 2500; t += 33) brain.update(t, true, x, -0.2f, false);
    assert(brain.dilation < 1.03f);
  }
  // Saccades are jumps: most of a new fixation is covered within 100 ms.
  {
    GazeBrain brain(5);
    brain.update(0, false, 0, 0, false);            // picks a fixation at t=0
    const float startX = brain.lookX, startY = brain.lookY;
    uint32_t t = 0;
    for (; t <= 99; t += 33) brain.update(t, false, 0, 0, false);
    // Where it was heading: run long enough to settle, same seed.
    GazeBrain settled(5);
    for (uint32_t s = 0; s < 800; s += 33) settled.update(s, false, 0, 0, false);
    const float jump = std::hypot(settled.lookX - startX, settled.lookY - startY);
    const float covered = jump - std::hypot(settled.lookX - brain.lookX, settled.lookY - brain.lookY);
    assert(jump > 0.2f && covered > 0.9f * jump);
  }
  std::printf("gaze brain: all tests passed\n");
}
