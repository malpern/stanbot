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

int main() {
  openUntilAskedToSleep();
  closesOverTheCloseTimeThenLetsTheScreenGoDark();
  wakingOpensFromWhereverTheLidsAre();
  repeatedRequestsDoNotRestartTheAnimation();
  std::puts("sleep curtain: all tests passed");
  return 0;
}
