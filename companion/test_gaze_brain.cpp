#include "../firmware/lib/StanbotEyes/src/GazeBrain.h"
#include <cassert>
#include <cmath>
#include <cstdio>

using stanbot::GazeBrain;

static float distance(const GazeBrain& b, float x, float y) { return std::hypot(b.lookX - x, b.lookY - y); }

int main() {
  // Nobody engaging, a face right in the middle: the eyes mostly rest a little
  // away, and look at the person only rarely. Five minutes, since calm eyes
  // make few moves and one minute is too few to count glances in.
  {
    GazeBrain brain(1234);
    int near = 0, total = 0;
    for (uint32_t t = 0; t < 300000; t += 33) {
      brain.update(t, true, 0.0f, 0.0f, false);
      if (t > 2000) { ++total; if (distance(brain, 0, 0) < 0.1f) ++near; }
      assert(brain.dilation < 1.01f);
    }
    std::printf("  not engaged: looking at the face %.0f%% of the time\n", 100.0 * near / total);
    assert(near * 100 < total * 10);   // rare looks, not a stare
  }
  // Nobody at all: drifts a little either side of centre, never far.
  {
    GazeBrain brain(99);
    int middle = 0, total = 0;
    float minX = 1, maxX = -1;
    for (uint32_t t = 0; t < 300000; t += 33) {
      brain.update(t, false, 0, 0, false);
      if (t > 2000) {
        ++total;
        if (std::fabs(brain.lookX) < 0.05f) ++middle;
        minX = brain.lookX < minX ? brain.lookX : minX;
        maxX = brain.lookX > maxX ? brain.lookX : maxX;
      }
    }
    std::printf("  nobody: dead centre %.0f%%, x range %.2f..%.2f\n", 100.0 * middle / total, minX, maxX);
    assert(middle * 100 < total * 15);
    assert(minX > -0.5f && maxX < 0.5f);     // a small drift, not across the screen
    assert(minX < -0.1f && maxX > 0.1f);     // but it does drift
  }
  // Calm, the point of the 2026-09-17 retune: with nobody there the eyes start
  // a new move at most about once every five seconds, and no single frame
  // moves them far enough to catch the eye.
  {
    GazeBrain brain(31);
    int moves = 0;
    float lastX = 0, lastY = 0, fastest = 0;
    bool moving = false;
    for (uint32_t t = 0; t < 600000; t += 33) {
      brain.update(t, false, 0, 0, false);
      const float step = std::hypot(brain.lookX - lastX, brain.lookY - lastY);
      if (t > 0) fastest = step > fastest ? step : fastest;
      if (step > 0.004f && !moving) ++moves;
      moving = step > 0.004f;
      lastX = brain.lookX;
      lastY = brain.lookY;
    }
    std::printf("  calm: %d moves in 10 min, largest per-frame step %.3f\n", moves, fastest);
    assert(moves <= 600 / 5 + 1);
    assert(fastest <= GazeBrain::kMaxSpeed * 0.033f + 0.001f);   // never a snap
  }
  // Engaged: settles on the face within about a second, follows a slowly
  // moving face, pupils widen a little.
  {
    GazeBrain brain(7);
    uint32_t t = 0;
    for (; t < 6000; t += 33) brain.update(t, true, -0.3f, 0.2f, false);
    const uint32_t engagedAt = t;
    for (; t < engagedAt + 1200; t += 33) brain.update(t, true, 0.4f, -0.2f, true);
    assert(distance(brain, 0.4f, -0.2f) < 0.08f);
    for (; t < engagedAt + 2500; t += 33) brain.update(t, true, 0.4f, -0.2f, true);
    assert(brain.dilation > 1.1f && brain.dilation <= GazeBrain::kDilated + 0.001f);
    float x = 0.4f;
    for (int i = 0; i < 90; ++i, t += 33) {
      x -= 0.003f;                            // a person shifting in their seat
      brain.update(t, true, x, -0.2f, true);
      if (i > 30) assert(distance(brain, x, -0.2f) < 0.06f);
    }
    // Turns away: pupils relax, more slowly than they widened.
    const uint32_t awayAt = t;
    for (; t < awayAt + 500; t += 33) brain.update(t, true, x, -0.2f, false);
    assert(brain.dilation > 1.05f);           // still relaxing after half a second
    for (; t < awayAt + 8000; t += 33) brain.update(t, true, x, -0.2f, false);
    assert(brain.dilation < 1.01f);
  }
  // Moves glide: little of a move is covered in the first frame, most of it
  // within a second.
  {
    GazeBrain brain(5);
    brain.update(0, false, 0, 0, false);            // picks a fixation at t=0
    GazeBrain settled(5);
    for (uint32_t s = 0; s < 3000; s += 33) settled.update(s, false, 0, 0, false);
    const float jump = std::hypot(settled.lookX, settled.lookY);
    brain.update(33, false, 0, 0, false);
    const float firstFrame = std::hypot(brain.lookX, brain.lookY);
    for (uint32_t t = 66; t <= 990; t += 33) brain.update(t, false, 0, 0, false);
    const float oneSecond = std::hypot(brain.lookX, brain.lookY);
    std::printf("  glide: %.0f%% after one frame, %.0f%% after 1 s\n", 100 * firstFrame / jump, 100 * oneSecond / jump);
    assert(jump > 0.1f);
    assert(firstFrame < 0.25f * jump);
    assert(oneSecond > 0.9f * jump);
  }
  std::printf("gaze brain: all tests passed\n");
}
