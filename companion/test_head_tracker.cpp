#include "../firmware/camera_stream/head_tracker.h"
#include <cassert>
#include <cmath>

using stanbot::FollowCommand;
using stanbot::FollowConfig;
using stanbot::FollowLimits;
using stanbot::FollowMode;
using stanbot::HeadTracker;

namespace {

// Fixed limits owned by the tests. Deliberately NOT stanbot::kFollowLimits:
// that constant is narrowed and re-measured per calibration session, and the
// logic these tests pin must not appear to change when it does.
const FollowLimits kLimits = {460 - 144, 460 + 144, 460, 620, 620 + 32, 620, +1, true};
const FollowConfig kConfig{};

// Tick until the controller stops sending, returning how many goals it
// issued. Every goal must move by at most `maxStep` and stay inside the limits.
int drain(HeadTracker& tracker, uint32_t& now, int maxStep,
          const FollowLimits& limits = kLimits) {
  int sent = 0;
  int lastYaw = tracker.commandedYaw(), lastPitch = tracker.commandedPitch();
  for (int i = 0; i < 200; ++i) {
    now += kConfig.controlPeriodMs;
    const FollowCommand command = tracker.step(now);
    if (!command.send) return sent;
    ++sent;
    assert(std::abs(command.yaw - lastYaw) <= maxStep);
    assert(std::abs(command.pitch - lastPitch) <= maxStep);
    assert(command.yaw >= limits.yawMin && command.yaw <= limits.yawMax);
    assert(command.pitch >= limits.pitchMin && command.pitch <= limits.pitchMax);
    lastYaw = command.yaw;
    lastPitch = command.pitch;
  }
  assert(false && "controller never settled");
  return sent;
}

void protocolValidation() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 620, now);
  assert(!tracker.observe(1, 1.5f, 0.0f, 0.9f, now));    // x out of range
  assert(!tracker.observe(1, 0.0f, -1.5f, 0.9f, now));   // y out of range
  assert(!tracker.observe(1, 0.0f, 0.0f, 1.2f, now));    // confidence out of range
  assert(!tracker.observe(1, NAN, 0.0f, 0.9f, now));     // NaN
  assert(!tracker.observe(0, 0.5f, 0.0f, 0.9f, now));    // sequences start above 0
  assert(tracker.observe(5, 0.5f, 0.0f, 0.9f, now));
  assert(!tracker.observe(5, 0.5f, 0.0f, 0.9f, now));    // repeated sequence
  assert(!tracker.observe(3, 0.5f, 0.0f, 0.9f, now));    // older sequence
  assert(tracker.observe(6, 0.5f, 0.0f, 0.9f, now));
  // Below the confidence threshold: consumed, but not attended to.
  HeadTracker shy(kLimits, kConfig);
  shy.begin(460, 620, now);
  assert(!shy.observe(1, 0.5f, 0.0f, 0.69f, now));
  assert(shy.mode() == FollowMode::Idle);
  assert(!shy.step(now + kConfig.controlPeriodMs).send);
}

void idleUntilObserved() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 620, now);
  assert(tracker.mode() == FollowMode::Idle);
  for (int i = 0; i < 50; ++i) {
    now += kConfig.controlPeriodMs;
    assert(!tracker.step(now).send);
  }
  assert(tracker.commandedYaw() == 460 && tracker.commandedPitch() == 620);
}

void observationAppliedOnce() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 620, now);
  // x = +0.5 asks for +48 raw once. Seven ticks of six reach 502, the last six
  // are inside the raw deadband and are left alone, and the same frame is
  // never counted again however many ticks pass before the next one.
  assert(tracker.observe(1, 0.5f, 0.0f, 0.9f, now));
  assert(tracker.mode() == FollowMode::Attending);
  assert(drain(tracker, now, kConfig.maxStepRaw) == 7);
  assert(tracker.commandedYaw() == 502);
  assert(tracker.commandedPitch() == 620);
}

void centreDeadbandHoldsStill() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 620, now);
  assert(tracker.observe(1, 0.05f, -0.07f, 0.9f, now));  // inside the centre band
  assert(tracker.mode() == FollowMode::Attending);
  assert(drain(tracker, now, kConfig.maxStepRaw) == 0);
  assert(tracker.commandedYaw() == 460 && tracker.commandedPitch() == 620);
}

void rawDeadbandNeverChasesStandingError() {
  uint32_t now = 1000;
  // ~9 raw requested: one step of six, then a residual of three that is
  // smaller than the standing error and is accepted as arrived.
  HeadTracker nine(kLimits, kConfig);
  nine.begin(460, 620, now);
  assert(nine.observe(1, 0.09f, 0.0f, 0.9f, now));
  assert(drain(nine, now, kConfig.maxStepRaw) == 1);
  assert(nine.commandedYaw() == 466);
  // With the centre band removed, a request of ~7 raw is inside the raw
  // deadband from the start and is declined outright. Re-issuing it is
  // exactly the hunting the servo review predicts for I = 0.
  FollowConfig wide = kConfig;
  wide.centreDeadband = 0.0f;
  HeadTracker seven(kLimits, wide);
  seven.begin(460, 620, now);
  assert(seven.observe(1, 0.07f, 0.0f, 0.9f, now));
  assert(drain(seven, now, kConfig.maxStepRaw) == 0);
  assert(seven.commandedYaw() == 460);
}

void clampsAtLimits() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 620, now);
  for (uint32_t sequence = 1; sequence <= 20; ++sequence) {
    assert(tracker.observe(sequence, 1.0f, -1.0f, 0.95f, now));
    now += 200;
    for (int i = 0; i < 3; ++i) {
      now += kConfig.controlPeriodMs;
      const FollowCommand command = tracker.step(now);
      assert(command.yaw <= kLimits.yawMax && command.pitch <= kLimits.pitchMax);
    }
  }
  assert(tracker.commandedYaw() > kLimits.yawMax - kConfig.deadbandRaw);
  assert(tracker.commandedPitch() > kLimits.pitchMax - kConfig.deadbandRaw);
  // Pitch never goes below rest: -raw from rest is never commanded here.
  HeadTracker down(kLimits, kConfig);
  down.begin(460, 620, now);
  assert(down.observe(1, 0.0f, 1.0f, 0.95f, now));      // face at the bottom: tilt down
  assert(drain(down, now, kConfig.maxStepRaw) == 0);
  assert(down.commandedPitch() == kLimits.pitchMin);
}

void pitchSignFollowsLimits() {
  FollowLimits flipped = kLimits;
  flipped.pitchUpSign = -1;
  flipped.pitchMin = 620 - 32;
  HeadTracker tracker(flipped, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 620, now);
  assert(tracker.observe(1, 0.0f, -0.5f, 0.9f, now));    // face high in the frame
  assert(drain(tracker, now, kConfig.maxStepRaw, flipped) > 0);
  assert(tracker.commandedPitch() < 620);                 // "up" is -raw on this unit
  assert(tracker.commandedPitch() >= flipped.pitchMin);
}

void timeoutReturnsToRestSlowly() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 620, now);
  const uint32_t observedAt = now;
  assert(tracker.observe(1, 0.5f, -0.5f, 0.9f, observedAt));
  drain(tracker, now, kConfig.maxStepRaw);
  const int awayYaw = tracker.commandedYaw(), awayPitch = tracker.commandedPitch();
  assert(awayYaw > 460 && awayPitch > 620);
  // The timeout runs from the observation, not from the last goal. One
  // millisecond short of it the head is still attending: nothing moves,
  // nothing returns.
  now = observedAt + kConfig.targetTimeoutMs - 1;
  assert(!tracker.step(now).send);
  assert(tracker.mode() == FollowMode::Attending);
  // Past it, the head comes home at the slower rest step, and the mode reads
  // Returning for every goal on the way.
  now += kConfig.controlPeriodMs;
  const FollowCommand first = tracker.step(now);
  assert(first.send && first.mode == FollowMode::Returning);
  assert(std::abs(first.yaw - awayYaw) <= kConfig.restStepRaw);
  assert(std::abs(first.pitch - awayPitch) <= kConfig.restStepRaw);
  drain(tracker, now, kConfig.restStepRaw);
  assert(tracker.mode() == FollowMode::Idle);
  // Rest is reached to within the raw deadband, never chased further.
  assert(std::abs(tracker.commandedYaw() - kLimits.yawRest) < kConfig.deadbandRaw);
  assert(std::abs(tracker.commandedPitch() - kLimits.pitchRest) < kConfig.deadbandRaw);
  // A new face interrupts the idle rest.
  assert(tracker.observe(2, -0.5f, 0.0f, 0.9f, now));
  assert(tracker.mode() == FollowMode::Attending);
}

void controlPeriodIsRespected() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 620, now);
  assert(tracker.observe(1, 1.0f, 0.0f, 0.9f, now));     // asks for 96 raw: 16 steps
  int sent = 0;
  for (int i = 0; i < 100; ++i) {                          // 100 ticks of 10 ms
    now += 10;
    if (tracker.step(now).send) ++sent;
  }
  // 1000 ms at one goal per 80 ms is 12 or 13 opportunities, well short of
  // the 16 the goal wants: the period, not the goal, sets the pace.
  assert(sent >= 12 && sent <= 13);
}

void beginAdoptsCurrentPosition() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(500, 640, now);
  assert(tracker.commandedYaw() == 500 && tracker.commandedPitch() == 640);
  assert(!tracker.step(now + kConfig.controlPeriodMs).send);
  // Outside the limits is clamped, never adopted as a goal beyond them.
  tracker.begin(100, 900, now);
  assert(tracker.commandedYaw() == kLimits.yawMin && tracker.commandedPitch() == kLimits.pitchMax);
}

}  // namespace

int main() {
  protocolValidation();
  idleUntilObserved();
  observationAppliedOnce();
  centreDeadbandHoldsStill();
  rawDeadbandNeverChasesStandingError();
  clampsAtLimits();
  pitchSignFollowsLimits();
  timeoutReturnsToRestSlowly();
  controlPeriodIsRespected();
  beginAdoptsCurrentPosition();
}
