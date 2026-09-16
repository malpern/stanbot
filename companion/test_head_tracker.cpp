#include "../firmware/camera_stream/head_tracker.h"
#include <cassert>
#include <cstdio>
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
  // x = +0.5 asks for 0.5 * rawPerUnitX * gain = +29 raw once, reached in five
  // ticks of six with the last step short; what remains is inside the raw
  // deadband and is left alone, and the same frame is never counted again
  // however many ticks pass before the next one.
  const int expected = static_cast<int>(0.5f * kConfig.rawPerUnitX * kConfig.gain + 0.5f);
  assert(tracker.observe(1, 0.5f, 0.0f, 0.9f, now));
  assert(tracker.mode() == FollowMode::Attending);
  // Steps of maxStepRaw until what is left is inside the raw deadband, which
  // the controller accepts as arrived rather than chasing.
  int remaining = expected, expectedTicks = 0;
  while (remaining >= kConfig.deadbandRaw) {
    remaining -= remaining < kConfig.maxStepRaw ? remaining : kConfig.maxStepRaw;
    ++expectedTicks;
  }
  assert(drain(tracker, now, kConfig.maxStepRaw) == expectedTicks);
  assert(tracker.commandedYaw() == 460 + expected - remaining);
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
  // The face position that asks for a given number of raw steps, whatever the
  // gain and the field-of-view estimate are set to.
  auto offsetFor = [](int raw) { return raw / (kConfig.rawPerUnitX * kConfig.gain); };
  // 9 raw requested: one step of six, then a residual of three that is smaller
  // than the standing error and is accepted as arrived.
  HeadTracker nine(kLimits, kConfig);
  nine.begin(460, 620, now);
  assert(nine.observe(1, offsetFor(9), 0.0f, 0.9f, now));
  assert(drain(nine, now, kConfig.maxStepRaw) == 1);
  assert(nine.commandedYaw() == 466);
  // With the centre band removed, a request of 7 raw is inside the raw
  // deadband from the start and is declined outright. Re-issuing it is
  // exactly the hunting the servo review predicts for I = 0.
  FollowConfig wide = kConfig;
  wide.centreDeadband = 0.0f;
  HeadTracker seven(kLimits, wide);
  seven.begin(460, 620, now);
  assert(seven.observe(1, offsetFor(7), 0.0f, 0.9f, now));
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
  // Full gain here, so the goal is bigger than the ticks available and the
  // period is plainly what limits the pace.
  FollowConfig full = kConfig;
  full.gain = 1.0f;
  HeadTracker tracker(kLimits, full);
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

// Yaw only: pitch is never commanded, even when the target is far above or
// below centre, when it times out and returns to rest, or when it starts
// outside the pitch limits. The 2026-09-15 session moved pitch by exactly
// that return-to-rest path.
void pitchDisabledNeverMovesPitch() {
  FollowConfig config;
  config.pitchEnabled = false;
  for (int startPitch : {620, 700, 560}) {       // inside, above and below the limits
    HeadTracker tracker(kLimits, config);
    uint32_t now = 1000;
    tracker.begin(460, startPitch, now);
    assert(tracker.commandedPitch() == startPitch);
    assert(tracker.observe(1, 0.6f, -0.9f, 0.95f, now));   // right and high
    int sent = 0;
    for (int i = 0; i < 300; ++i) {
      now += config.controlPeriodMs;
      const FollowCommand command = tracker.step(now);
      assert(command.pitch == startPitch);
      if (command.send) ++sent;
    }
    assert(sent > 0);                                       // yaw did follow
    assert(tracker.mode() == FollowMode::Idle);             // timed out and returned
    assert(std::abs(tracker.commandedYaw() - kLimits.yawRest) < config.deadbandRaw);  // settles within the deadband
    assert(tracker.commandedPitch() == startPitch);
  }
  // Yaw still honours its limits with pitch disabled.
  HeadTracker tracker(kLimits, config);
  uint32_t now = 1000;
  tracker.begin(kLimits.yawMax - 4, 620, now);
  assert(tracker.observe(1, 1.0f, 0.0f, 0.95f, now));
  for (int i = 0; i < 50; ++i) {
    now += config.controlPeriodMs;
    const FollowCommand command = tracker.step(now);
    assert(command.yaw <= kLimits.yawMax);
  }
}

// Closed loop with the real delay: the camera frame a target comes from was
// captured before the head acted on the frames before it. Session 5
// (2026-09-16) hunted across the whole range with a ~3 s period because each
// observation asked for motion that was already under way. Simulated here with
// a face at a fixed angle, frames at 5 fps, and 300 ms of pipeline delay.
struct LoopResult { double finalOffset; int reversals; double worstOffset; int travel; };

LoopResult simulate(bool compensateLatency, double fieldOfViewError = 1.0) {
  FollowConfig config;
  config.pitchEnabled = false;
  HeadTracker tracker(kLimits, config);
  uint32_t now = 100000;
  int head = kLimits.yawRest;                 // the servo follows commands exactly
  tracker.begin(head, 620, now);
  const int faceRaw = kLimits.yawRest + 60;   // a face 60 raw to the robot's right
  struct Frame { uint32_t sentMs; int headThen; uint32_t sequence; };
  Frame pipeline[8]{};
  unsigned queued = 0;
  uint32_t nextFrameMs = now, sequence = 0;
  double worst = 0, last = 0;
  int reversals = 0, travel = 0;
  for (int tick = 0; tick < 250; ++tick) {    // 250 x 80 ms = 20 s
    now += config.controlPeriodMs;
    if (static_cast<int32_t>(now - nextFrameMs) >= 0) {      // a frame is captured
      nextFrameMs = now + 200;                               // 5 fps
      if (queued < 8) pipeline[queued++] = {now, head, ++sequence};
    }
    if (queued > 0 && static_cast<int32_t>(now - pipeline[0].sentMs) >= 300) {  // it arrives 300 ms later
      const Frame frame = pipeline[0];
      for (unsigned i = 1; i < queued; ++i) pipeline[i - 1] = pipeline[i];
      --queued;
      // Where the face appeared in that frame, given where the head was then.
      const double offset = (faceRaw - frame.headThen) / (config.rawPerUnitX * fieldOfViewError);
      worst = offset > worst ? offset : (-offset > worst ? -offset : worst);
      if ((offset > 0) != (last > 0) && last != 0) ++reversals;
      last = offset;
      tracker.observe(frame.sequence, static_cast<float>(offset), 0.0f, 0.95f, now,
                      compensateLatency ? frame.sentMs : now);
    }
    const FollowCommand command = tracker.step(now);
    if (command.send) {
      travel += std::abs(command.yaw - head);
      head = command.yaw;                     // the servo is where it was told
    }
  }
  return {(faceRaw - head) / static_cast<double>(config.rawPerUnitX), reversals, worst, travel};
}

void closedLoopSettlesInsteadOfHunting() {
  const LoopResult fixed = simulate(true);
  std::printf("  compensated:   final %.3f reversals %d travel %d\n", fixed.finalOffset, fixed.reversals, fixed.travel);
  const LoopResult raw = simulate(false);
  std::printf("  uncompensated: final %.3f reversals %d travel %d\n", raw.finalOffset, raw.reversals, raw.travel);
  const LoopResult over = simulate(true, 1.0 / 1.6);
  std::printf("  over-gained:   final %.3f reversals %d travel %d\n", over.finalOffset, over.reversals, over.travel);
  // Settles near the centre without crossing it. The residual is the raw
  // deadband divided by the gain, about 0.14 of the frame or 4 degrees: the
  // price of never chasing the servos' standing error.
  assert(std::fabs(fixed.finalOffset) <= 0.16);
  assert(fixed.reversals <= 1);
  // Correcting from where the head is now instead makes it travel further for
  // the same job, and cross the centre. This simulated servo is ideal, so it
  // understates it; on the robot the same loop hunted across its whole range.
  assert(raw.travel > fixed.travel * 6 / 5);
  assert(raw.reversals > fixed.reversals);
  // A field of view 1.6x smaller than rawPerUnitX assumes: still settles,
  // because each correction takes only `gain` of the measured error.
  assert(std::fabs(over.finalOffset) <= 0.2);
  assert(over.reversals <= 2);
}

int main() {
  closedLoopSettlesInsteadOfHunting();
  pitchDisabledNeverMovesPitch();
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
