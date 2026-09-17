#pragma once
// When the independent cutoff task removes motor power. Pure, so it is tested
// natively by companion/test_power_lease.cpp.
//
// Every power window has a lease and a hard maximum, both from its start. The
// cutoff fires when the lease runs out without renewal, or at the maximum,
// whichever comes first. A window nobody renews (every one-shot test) behaves
// exactly as before: lease == maximum == the deadline it was opened with.
//
// Head following renews the lease while it is still seeing a face, so a
// session no longer has to end every 20 s. What makes that safe is that the
// renewal comes from the control loop: if the loop hangs, stops getting
// targets, or is starved, renewal stops and power goes off within one lease,
// the same bound the fixed deadline gave. The hard maximum still caps the
// window whatever the loop does.
#include <cstdint>

namespace stanbot {

struct LeaseTimes {
  uint32_t startMs;
  uint32_t renewedMs;   // == startMs until renewed
  uint32_t leaseMs;
  uint32_t maxMs;
};

// Milliseconds until the cutoff should fire; 0 means now.
inline uint32_t leaseRemainingMs(const LeaseTimes& t, uint32_t nowMs) {
  const uint32_t sinceStart = nowMs - t.startMs;
  const uint32_t sinceRenew = nowMs - t.renewedMs;
  // A renewal stamped after `now` (read racing a write) counts as just renewed.
  const uint32_t leaseLeft = static_cast<int32_t>(sinceRenew) < 0 ? t.leaseMs
                           : (sinceRenew >= t.leaseMs ? 0 : t.leaseMs - sinceRenew);
  const uint32_t maxLeft = sinceStart >= t.maxMs ? 0 : t.maxMs - sinceStart;
  return leaseLeft < maxLeft ? leaseLeft : maxLeft;
}

// Following: renew only while a target was accepted recently, and never in
// a way that could outlast the hard maximum (leaseRemainingMs caps that).
inline bool followShouldRenew(uint32_t nowMs, uint32_t lastTargetMs, uint32_t renewedMs,
                              uint32_t idleLimitMs, uint32_t renewEveryMs) {
  return nowMs - lastTargetMs < idleLimitMs && nowMs - renewedMs >= renewEveryMs;
}

enum class FollowEnd { None, Idle, MaxDuration, LeaseLapsing };

// Why a session should stop now, checked each loop iteration. It ends itself
// `marginMs` before the cutoff would, so power is removed by the session's
// own orderly path rather than by the watchdog.
inline FollowEnd followShouldEnd(const LeaseTimes& t, uint32_t nowMs, uint32_t lastTargetMs,
                                 uint32_t idleLimitMs, uint32_t marginMs) {
  if (nowMs - t.startMs + marginMs >= t.maxMs) return FollowEnd::MaxDuration;
  if (nowMs - lastTargetMs >= idleLimitMs) return FollowEnd::Idle;
  if (leaseRemainingMs(t, nowMs) <= marginMs) return FollowEnd::LeaseLapsing;
  return FollowEnd::None;
}

}  // namespace stanbot
