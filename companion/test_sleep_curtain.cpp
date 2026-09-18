#include "../firmware/lib/StanbotEyes/src/SleepCurtain.h"
#include <cassert>
#include <cstdio>

using stanbot::SleepCurtain;

void openUntilAskedToSleep() {
  SleepCurtain curtain;
  assert(curtain.openness(1000) == 1.0f);
  assert(!curtain.asleepWanted());
  assert(!curtain.closed(1000));
}

void closesOverTheCloseTimeThenLetsTheScreenGoDark() {
  SleepCurtain curtain;
  uint32_t now = 1000;
  curtain.close(now);
  assert(curtain.asleepWanted());
  assert(!curtain.closed(now));
  const float half = curtain.openness(now + SleepCurtain::kCloseMs / 2);
  assert(half < 0.9f && half > 0.1f);                      // moving, not snapping
  assert(curtain.openness(now + 100) > half);              // and eased, not linear at the start
  assert(curtain.openness(now + SleepCurtain::kCloseMs) == 0.0f);
  assert(curtain.closed(now + SleepCurtain::kCloseMs));
  assert(curtain.closed(now + 10000));
}

void wakingOpensFromWhereverTheLidsAre() {
  SleepCurtain curtain;
  uint32_t now = 1000;
  curtain.close(now);
  now += SleepCurtain::kCloseMs / 2;
  const float interrupted = curtain.openness(now);
  curtain.open(now);
  assert(!curtain.asleepWanted());
  assert(curtain.openness(now) == interrupted);            // continues, never jumps
  assert(curtain.openness(now + SleepCurtain::kOpenMs) == 1.0f);
  assert(!curtain.closed(now + SleepCurtain::kOpenMs));
}

void repeatedRequestsDoNotRestartTheAnimation() {
  SleepCurtain curtain;
  uint32_t now = 1000;
  curtain.close(now);
  const float at300 = curtain.openness(now + 300);
  curtain.close(now + 300);                                 // asked again
  assert(curtain.openness(now + 300) == at300);
  assert(curtain.closed(now + SleepCurtain::kCloseMs));
}

// Coming back from a reboot: the eyes are shut when the face appears, and then
// open slowly -- over the same 2.4 s the Mac's own eyes take, so the two read as
// one thing rather than two.
static void bootStartsShutAndOpensSlowly() {
  stanbot::SleepCurtain curtain;
  uint32_t now = 5000;
  curtain.startClosed(now);
  assert(curtain.openness(now) == 0.0f);
  assert(curtain.closed(now));

  curtain.openAfterBootForTest(now);
  // A third of the way in it is genuinely part open: not snapped, not still shut.
  const float third = curtain.openness(now + stanbot::SleepCurtain::kBootOpenMs / 3);
  assert(third > 0.05f && third < 0.6f);
  // And it is SLOWER than an ordinary wake: at the moment a wake would have
  // finished, this is nowhere near.
  assert(curtain.openness(now + stanbot::SleepCurtain::kOpenMs) < 0.35f);
  assert(curtain.openness(now + stanbot::SleepCurtain::kBootOpenMs) == 1.0f);

  // An ordinary wake afterwards is still quick: the long opening belongs to the
  // boot, not to the curtain for ever.
  curtain.close(now + 10000);
  curtain.open(now + 20000);
  assert(curtain.openness(now + 20000 + stanbot::SleepCurtain::kOpenMs) == 1.0f);
}

int main() {
  openUntilAskedToSleep();
  closesOverTheCloseTimeThenLetsTheScreenGoDark();
  wakingOpensFromWhereverTheLidsAre();
  repeatedRequestsDoNotRestartTheAnimation();
  bootStartsShutAndOpensSlowly();
  std::puts("sleep curtain: all tests passed");
  return 0;
}
