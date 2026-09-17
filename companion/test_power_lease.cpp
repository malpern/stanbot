#include "../firmware/camera_stream/power_lease.h"
#include <cassert>
#include <cstdio>

using namespace stanbot;

int main() {
  // Never renewed: the old fixed deadline, exactly.
  LeaseTimes fixed{1000, 1000, 2000, 2000};
  assert(leaseRemainingMs(fixed, 1000) == 2000);
  assert(leaseRemainingMs(fixed, 2999) == 1);
  assert(leaseRemainingMs(fixed, 3000) == 0);
  assert(leaseRemainingMs(fixed, 90000) == 0);

  // Renewed: the lease moves, the maximum does not.
  LeaseTimes renewed{1000, 15000, 20000, 180000};
  assert(leaseRemainingMs(renewed, 20000) == 15000);
  assert(leaseRemainingMs(renewed, 35000) == 0);          // not renewed for a whole lease
  LeaseTimes late{1000, 175000, 20000, 180000};
  assert(leaseRemainingMs(late, 176000) == 5000);         // capped by the maximum
  assert(leaseRemainingMs(late, 181000) == 0);
  // A renewal read as slightly in the future is treated as fresh, not as a
  // wrapped, enormous age that would cut power at once or never.
  LeaseTimes racing{1000, 5001, 20000, 180000};
  assert(leaseRemainingMs(racing, 5000) == 20000);
  // millis() wrap.
  LeaseTimes wrap{0xFFFFF000u, 0xFFFFF000u, 20000, 180000};
  assert(leaseRemainingMs(wrap, 0xFFFFF000u + 10000) == 10000);
  assert(leaseRemainingMs(wrap, 0xFFFFF000u + 20000) == 0);

  // Renewal needs a recent target and is rate limited.
  assert(followShouldRenew(10000, 9000, 8000, 12000, 1000));
  assert(!followShouldRenew(10000, 9000, 9500, 12000, 1000));   // renewed 0.5 s ago
  assert(!followShouldRenew(30000, 17000, 20000, 12000, 1000)); // no face for 13 s

  // Ending: idle, maximum, and a lease about to lapse, each before the cutoff.
  LeaseTimes session{0, 0, 20000, 180000};
  assert(followShouldEnd(session, 5000, 4000, 12000, 500) == FollowEnd::None);
  assert(followShouldEnd(session, 16000, 4000, 12000, 500) == FollowEnd::Idle);
  assert(followShouldEnd(session, 19600, 19000, 30000, 500) == FollowEnd::LeaseLapsing);
  LeaseTimes kept{0, 179000, 20000, 180000};
  assert(followShouldEnd(kept, 179400, 179300, 12000, 500) == FollowEnd::None);
  assert(followShouldEnd(kept, 179500, 179400, 12000, 500) == FollowEnd::MaxDuration);
  // Whatever renewals happen, the session always ends before the cutoff:
  // simulate a loop that renews every second with a face always present.
  LeaseTimes loop{0, 0, 20000, 180000};
  uint32_t now = 0, endedAt = 0;
  for (; now < 400000; now += 10) {
    if (followShouldRenew(now, now, loop.renewedMs, 12000, 1000)) loop.renewedMs = now;
    if (followShouldEnd(loop, now, now, 12000, 500) != FollowEnd::None) { endedAt = now; break; }
    assert(leaseRemainingMs(loop, now) > 0);
  }
  assert(endedAt == 179500);
  std::printf("power lease: all tests passed\n");
}
