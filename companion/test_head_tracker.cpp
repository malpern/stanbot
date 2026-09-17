#include "../firmware/camera_stream/head_tracker.h"
#include <cassert>
#include <cstdio>
#include <cmath>
#include <initializer_list>

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
// Fixed steps and straight home, for the tests that count exact ticks or pin
// the return-to-rest path. Easing and search have their own tests below.
FollowConfig linearConfig() {
  FollowConfig config;
  config.ease = false;
  config.search = false;
  return config;
}
const FollowConfig kLinear = linearConfig();

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
  HeadTracker tracker(kLimits, kLinear);
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
  HeadTracker nine(kLimits, kLinear);
  nine.begin(460, 620, now);
  assert(nine.observe(1, offsetFor(9), 0.0f, 0.9f, now));
  assert(drain(nine, now, kConfig.maxStepRaw) == 1);
  assert(nine.commandedYaw() == 466);
  // With the centre band removed, a request of 7 raw is inside the raw
  // deadband from the start and is declined outright. Re-issuing it is
  // exactly the hunting the servo review predicts for I = 0.
  FollowConfig wide = kLinear;
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
  HeadTracker tracker(kLimits, kLinear);
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
  FollowConfig full = kLinear;
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
  FollowConfig config = kLinear;
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

// ---- Pitch following ------------------------------------------------------
// Pitch rest is not confirmed on this unit, so travel is bounded relative to
// where each session finds the head, and a lost target returns pitch there.

// Tick until nothing is sent; checks each goal against this session's bounds.
int drainPitch(HeadTracker& tracker, uint32_t& now, int maxStep) {
  int sent = 0, lastPitch = tracker.commandedPitch();
  for (int i = 0; i < 300; ++i) {
    now += kConfig.controlPeriodMs;
    const FollowCommand command = tracker.step(now);
    if (!command.send) return sent;
    ++sent;
    assert(std::abs(command.pitch - lastPitch) <= maxStep);
    assert(command.pitch >= tracker.pitchLow() && command.pitch <= tracker.pitchHigh());
    lastPitch = command.pitch;
  }
  assert(false && "controller never settled");
  return sent;
}

// Room to tilt that the fixed test limits do not clip.
FollowLimits roomyPitch() {
  FollowLimits limits = kLimits;
  limits.pitchMax = 700;
  limits.pitchUpTravel = 64;
  return limits;
}

void pitchFollowsUpAndDown() {
  const FollowLimits limits = roomyPitch();
  HeadTracker tracker(limits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 640, now);              // resting tilted up a little
  assert(tracker.pitchLow() == 620 && tracker.pitchHigh() == 704 - 4);
  // Face high in the frame: tilt up (+raw on this unit).
  assert(tracker.observe(1, 0.0f, -0.6f, 0.95f, now));
  assert(drainPitch(tracker, now, kConfig.maxStepRaw) > 0);
  const int up = tracker.commandedPitch();
  assert(up > 640 + kConfig.deadbandRaw);
  assert(tracker.commandedYaw() == 460);      // x was centred: yaw untouched
  // Face low in the frame: tilt back down, but never below 620.
  for (uint32_t seq = 2; seq < 12; ++seq) {
    assert(tracker.observe(seq, 0.0f, 1.0f, 0.95f, now));
    drainPitch(tracker, now, kConfig.maxStepRaw);
  }
  assert(tracker.commandedPitch() < up);
  assert(tracker.commandedPitch() >= 620 && tracker.commandedPitch() < 620 + kConfig.deadbandRaw);
}

void pitchUpTravelIsBoundedFromStart() {
  HeadTracker tracker(kLimits, kConfig);     // upTravel 32, pitchMax 652
  uint32_t now = 1000;
  tracker.begin(460, 605, now);
  assert(tracker.pitchHigh() == 605 + 32);
  for (uint32_t seq = 1; seq < 20; ++seq) {
    assert(tracker.observe(seq, 0.0f, -1.0f, 0.95f, now));
    drainPitch(tracker, now, kConfig.maxStepRaw);
  }
  assert(tracker.commandedPitch() <= 605 + 32);
  assert(tracker.commandedPitch() > 605 + 32 - kConfig.deadbandRaw);
  // Started high: capped by pitchMax, not by start + travel.
  HeadTracker high(kLimits, kConfig);
  high.begin(460, 640, now);
  assert(high.pitchHigh() == kLimits.pitchMax);
}

void lowRestIsNeverPressedLower() {
  // Session 2 found pitch resting at 601, below the BSP's 0 degrees.
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 601, now);
  assert(tracker.commandedPitch() == 601 && tracker.pitchLow() == 601);
  for (uint32_t seq = 1; seq < 10; ++seq) {
    assert(tracker.observe(seq, 0.0f, 1.0f, 0.95f, now));   // face at the bottom
    for (int i = 0; i < 20; ++i) {
      now += kConfig.controlPeriodMs;
      assert(tracker.step(now).pitch >= 601);
    }
  }
  assert(tracker.commandedPitch() == 601);
}

void lostTargetReturnsPitchToSessionStart() {
  const FollowLimits limits = roomyPitch();
  HeadTracker tracker(limits, kLinear);
  uint32_t now = 1000;
  tracker.begin(460, 640, now);
  assert(tracker.observe(1, 0.4f, -0.8f, 0.95f, now));
  drainPitch(tracker, now, kConfig.maxStepRaw);
  assert(tracker.commandedPitch() > 640 + kConfig.deadbandRaw);
  now += kConfig.targetTimeoutMs;
  drainPitch(tracker, now, kConfig.restStepRaw);
  assert(tracker.mode() == FollowMode::Idle);
  // Unconfirmed rest: back to where it started, not to pitchRest (620).
  assert(std::abs(tracker.commandedPitch() - 640) < kConfig.deadbandRaw);

  FollowLimits confirmed = limits;
  confirmed.pitchRestConfirmed = true;
  HeadTracker withRest(confirmed, kLinear);
  withRest.begin(460, 640, now);
  assert(withRest.observe(1, 0.0f, -0.8f, 0.95f, now));
  drainPitch(withRest, now, kConfig.maxStepRaw);
  now += kConfig.targetTimeoutMs;
  drainPitch(withRest, now, kConfig.restStepRaw);
  assert(std::abs(withRest.commandedPitch() - confirmed.pitchRest) < kConfig.deadbandRaw);
}

void pitchStartAcceptance() {
  assert(HeadTracker::pitchStartAcceptable(kLimits, 620));
  assert(HeadTracker::pitchStartAcceptable(kLimits, 601));
  assert(HeadTracker::pitchStartAcceptable(kLimits, 594));       // the rest that was refused on 2026-09-17
  assert(HeadTracker::pitchStartAcceptable(kLimits, 620 - 32));
  assert(!HeadTracker::pitchStartAcceptable(kLimits, 620 - 33));
  assert(HeadTracker::pitchStartAcceptable(kLimits, kLimits.pitchMax));
  assert(!HeadTracker::pitchStartAcceptable(kLimits, kLimits.pitchMax + 1));
  assert(!HeadTracker::pitchStartAcceptable(kLimits, -1));   // unpowered servo reads -1
}

// The session-5 hunt, on the pitch axis: frames 200 ms apart arriving 300 ms
// late, face held above the start. Also both axes at once.
struct PitchLoop { int finalError; int reversals; int travel; int yawError; };

PitchLoop simulatePitch(bool compensate, int faceYawRaw) {
  const FollowLimits limits = roomyPitch();
  HeadTracker tracker(limits, kConfig);
  uint32_t now = 100000;
  int yaw = limits.yawRest, pitch = 630;
  tracker.begin(yaw, pitch, now);
  const int facePitch = 630 + 40, faceYaw = limits.yawRest + faceYawRaw;
  struct Frame { uint32_t sentMs; int yawThen, pitchThen; uint32_t seq; };
  Frame q[8]{};
  unsigned queued = 0;
  uint32_t nextFrame = now, seq = 0;
  int reversals = 0, travel = 0, lastSign = 0;
  for (int tick = 0; tick < 250; ++tick) {
    now += kConfig.controlPeriodMs;
    if (static_cast<int32_t>(now - nextFrame) >= 0) {
      nextFrame = now + 200;
      if (queued < 8) q[queued++] = {now, yaw, pitch, ++seq};
    }
    if (queued > 0 && static_cast<int32_t>(now - q[0].sentMs) >= 300) {
      const Frame f = q[0];
      for (unsigned i = 1; i < queued; ++i) q[i - 1] = q[i];
      --queued;
      const float x = static_cast<float>(faceYaw - f.yawThen) / kConfig.rawPerUnitX;
      const float y = -static_cast<float>(facePitch - f.pitchThen) / kConfig.rawPerUnitY;  // above: negative y
      const int sign = (facePitch - f.pitchThen) > 0 ? 1 : ((facePitch - f.pitchThen) < 0 ? -1 : 0);
      if (sign != 0 && lastSign != 0 && sign != lastSign) ++reversals;
      if (sign != 0) lastSign = sign;
      tracker.observe(f.seq, x, y, 0.95f, now, compensate ? f.sentMs : now);
    }
    const FollowCommand command = tracker.step(now);
    if (command.send) {
      travel += std::abs(command.pitch - pitch);
      pitch = command.pitch;
      yaw = command.yaw;
    }
  }
  return {facePitch - pitch, reversals, travel, faceYaw - yaw};
}

void pitchClosedLoopSettles() {
  const PitchLoop fixed = simulatePitch(true, 0);
  const PitchLoop raw = simulatePitch(false, 0);
  std::printf("  pitch compensated:   error %d reversals %d travel %d\n", fixed.finalError, fixed.reversals, fixed.travel);
  std::printf("  pitch uncompensated: error %d reversals %d travel %d\n", raw.finalError, raw.reversals, raw.travel);
  // Residual: the raw deadband over the gain, as for yaw.
  assert(std::abs(fixed.finalError) <= 14);
  assert(fixed.reversals <= 1);
  assert(raw.travel > fixed.travel);
  const PitchLoop both = simulatePitch(true, 50);
  std::printf("  both axes:           pitch error %d yaw error %d reversals %d\n", both.finalError, both.yawError, both.reversals);
  assert(std::abs(both.finalError) <= 14 && std::abs(both.yawError) <= 16);
  assert(both.reversals <= 1);
}

// ---- Easing ---------------------------------------------------------------

void easingRampsUpAndSlowsDown() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 620, now);
  assert(tracker.observe(1, 1.0f, 0.0f, 0.95f, now));   // asks for 58 raw
  const int goal = 460 + static_cast<int>(kConfig.rawPerUnitX * kConfig.gain + 0.5f);
  int steps[40], count = 0, last = 460;
  for (int i = 0; i < 40; ++i) {
    now += kConfig.controlPeriodMs;
    const FollowCommand command = tracker.step(now);
    if (!command.send) break;
    steps[count++] = command.yaw - last;
    last = command.yaw;
  }
  assert(count > 3);
  assert(steps[0] == kConfig.easeMinStepRaw);                       // starts gently
  for (int i = 0; i < count; ++i) {
    assert(steps[i] > 0 && steps[i] <= kConfig.maxStepRaw);         // never faster than before, never back
    if (i > 0) assert(steps[i] <= steps[i - 1] + kConfig.easeAccelRaw);
  }
  int peak = 0;
  for (int i = 0; i < count; ++i) peak = steps[i] > peak ? steps[i] : peak;
  assert(peak == kConfig.maxStepRaw);                               // reaches full speed on a long move
  assert(steps[count - 1] < peak);                                  // and slows into the goal
  assert(last <= goal && goal - last < kConfig.deadbandRaw);        // no overshoot
}

void easingRestartsFromRestOnReversal() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 620, now);
  assert(tracker.observe(1, 1.0f, 0.0f, 0.95f, now));
  for (int i = 0; i < 4; ++i) { now += kConfig.controlPeriodMs; tracker.step(now); }
  const int before = tracker.commandedYaw();
  assert(tracker.observe(2, -1.0f, 0.0f, 0.95f, now));               // face jumps to the other side
  now += kConfig.controlPeriodMs;
  const FollowCommand command = tracker.step(now);
  assert(command.send && before - command.yaw == kConfig.easeMinStepRaw);
}

// ---- Search ---------------------------------------------------------------

struct SearchTrace { int maxYaw, minYaw, firstMoveAt, maxYawAt, minYawAt; int finalYaw; FollowMode finalMode; int sends; int minPitch, maxPitch; };

// Follow a face at (x, y) once, then lose it and tick for `seconds`.
SearchTrace loseFace(HeadTracker& tracker, float x, float y, uint32_t& now, int seconds,
                     int startYaw = 460, int startPitch = 630) {
  tracker.begin(startYaw, startPitch, now);
  assert(tracker.observe(1, x, y, 0.95f, now));
  const uint32_t lostAt = now;
  // Let the attend move play out, up to the timeout.
  while (now + kConfig.controlPeriodMs < lostAt + kConfig.targetTimeoutMs) {
    now += kConfig.controlPeriodMs;
    tracker.step(now);
  }
  const int lostYaw = tracker.commandedYaw();
  SearchTrace trace{lostYaw, lostYaw, -1, 0, 0, lostYaw, FollowMode::Idle, 0, tracker.commandedPitch(), tracker.commandedPitch()};
  for (int t = 0; t * static_cast<int>(kConfig.controlPeriodMs) < seconds * 1000; ++t) {
    now += kConfig.controlPeriodMs;
    const FollowCommand command = tracker.step(now);
    if (command.send) {
      ++trace.sends;
      if (trace.firstMoveAt < 0) trace.firstMoveAt = t;
    }
    if (command.yaw > trace.maxYaw) { trace.maxYaw = command.yaw; trace.maxYawAt = t; }
    if (command.yaw < trace.minYaw) { trace.minYaw = command.yaw; trace.minYawAt = t; }
    trace.minPitch = command.pitch < trace.minPitch ? command.pitch : trace.minPitch;
    trace.maxPitch = command.pitch > trace.maxPitch ? command.pitch : trace.maxPitch;
    assert(command.yaw >= kLimits.yawMin && command.yaw <= kLimits.yawMax);
    assert(command.pitch >= tracker.pitchLow() && command.pitch <= tracker.pitchHigh());
  }
  trace.finalYaw = tracker.commandedYaw();
  trace.finalMode = tracker.mode();
  return trace;
}

// A glance where they went, and only then the whole range. The owner asked for
// both: "I like the idea of a glance vs a full look around", after asking for
// "the full scan when it loses me. Only if it can't find me should it go back
// to center and rest."
void searchGlancesFirstThenLooksAroundEverything() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 630, now);
  // Face drifting off the right of the frame, then gone.
  SearchTrace right = loseFace(tracker, 0.7f, 0.0f, now, 1);
  assert(tracker.mode() == FollowMode::Searching);
  // Holds still for searchHoldMs before anything moves.
  assert(right.firstMoveAt < 0 || right.firstMoveAt * static_cast<int>(kConfig.controlPeriodMs) >= static_cast<int>(kConfig.searchHoldMs) - static_cast<int>(kConfig.controlPeriodMs));

  HeadTracker full(kLimits, kConfig);
  now = 1000;
  const SearchTrace trace = loseFace(full, 0.7f, 0.0f, now, 30);
  assert(trace.maxYawAt < trace.minYawAt);                  // right first, then left
  assert(trace.maxYaw >= kLimits.yawMax - kConfig.deadbandRaw);   // all the way out
  assert(trace.minYaw <= kLimits.yawMin + kConfig.deadbandRaw);
  assert(trace.finalMode == FollowMode::Idle);              // and only then home
  assert(std::abs(trace.finalYaw - kLimits.yawRest) < kConfig.deadbandRaw);
  std::printf("  search looked around yaw %d..%d (limits %d..%d)\n",
              trace.minYaw, trace.maxYaw, kLimits.yawMin, kLimits.yawMax);
}

void searchStartsLeftWhenTheFaceLeftLeft() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  const SearchTrace trace = loseFace(tracker, -0.7f, 0.0f, now, 30);
  assert(trace.minYawAt < trace.maxYawAt);                  // left first
  assert(trace.minYaw <= kLimits.yawMin + kConfig.deadbandRaw);
  assert(trace.finalMode == FollowMode::Idle);
}

void searchEndsWhenTheFaceReturns() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  loseFace(tracker, 0.7f, 0.0f, now, 2);
  assert(tracker.mode() == FollowMode::Searching);
  assert(tracker.observe(2, 0.3f, 0.0f, 0.95f, now));
  assert(tracker.mode() == FollowMode::Attending);
}

// The cheap stage on its own: someone who leans out of frame and back is found
// during the glance, and the head never goes near the limits.
void aGlanceIsOftenTheWholeSearch() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  tracker.begin(460, 630, now);
  assert(tracker.observe(1, 0.7f, 0.0f, 0.95f, now));
  // Attending keeps moving toward the face until the target times out, so the
  // place it was LOST is where the head is when the search begins, not where
  // it was when the last observation arrived.
  while (tracker.mode() != FollowMode::Searching) { now += kConfig.controlPeriodMs; tracker.step(now); }
  const int lost = tracker.commandedYaw();
  int furthest = lost;
  // 1.9 s: the 600 ms hold, out to the glance one way, dwell, and back across
  // to the other side. After that the second stage sets off for the limits.
  for (int i = 0; i < 24; ++i) {
    now += kConfig.controlPeriodMs;
    tracker.step(now);
    const int yaw = tracker.commandedYaw();
    if (std::abs(yaw - lost) > std::abs(furthest - lost)) furthest = yaw;
  }
  assert(tracker.mode() == FollowMode::Searching);
  const int reach = std::abs(furthest - lost);
  assert(reach > 0 && reach <= kConfig.searchGlanceRaw + kConfig.deadbandRaw);
  std::printf("  glance reached %d raw from where the face was lost (limit %d)\n",
              reach, kConfig.searchGlanceRaw);
  assert(tracker.observe(2, 0.1f, 0.0f, 0.95f, now));   // back again
  assert(tracker.mode() == FollowMode::Attending);
}

// The look around covers up and down as well, whichever way the face went.
void searchLooksUpAndDown() {
  const FollowLimits limits = roomyPitch();
  HeadTracker tracker(limits, kConfig);
  uint32_t now = 1000;
  const SearchTrace trace = loseFace(tracker, 0.0f, -0.9f, now, 30);
  assert(trace.maxPitch > trace.minPitch);
  assert(trace.maxPitch <= limits.pitchMax && trace.minPitch >= limits.pitchMin);
  assert(trace.finalMode == FollowMode::Idle);
  assert(std::abs(tracker.commandedPitch() - 630) < kConfig.deadbandRaw);   // back to the session start
}

void searchNeverMovesDisabledPitch() {
  FollowConfig config = kConfig;
  config.pitchEnabled = false;
  HeadTracker tracker(kLimits, config);
  uint32_t now = 1000;
  tracker.begin(460, 700, now);
  assert(tracker.observe(1, 0.8f, -0.9f, 0.95f, now));
  for (int i = 0; i < 300; ++i) {
    now += config.controlPeriodMs;
    assert(tracker.step(now).pitch == 700);
  }
  assert(tracker.mode() == FollowMode::Idle);
}

void searchIsClampedAndFinite() {
  HeadTracker tracker(kLimits, kConfig);
  uint32_t now = 1000;
  // Lost at the right-hand limit: the look around cannot go further right.
  const SearchTrace trace = loseFace(tracker, 1.0f, 0.0f, now, 30, kLimits.yawMax - 2);
  assert(trace.maxYaw <= kLimits.yawMax);
  assert(trace.finalMode == FollowMode::Idle);
  // A whole search, from losing the face to resting, stays well inside a session.
  HeadTracker timed(kLimits, kConfig);
  now = 1000;
  timed.begin(460, 630, now);
  assert(timed.observe(1, 0.7f, 0.0f, 0.95f, now));
  int ticks = 0;
  do { now += kConfig.controlPeriodMs; timed.step(now); ++ticks; }
  while (timed.mode() != FollowMode::Idle && ticks < 1000);
  std::printf("  search: idle %d ms after the last target\n", ticks * static_cast<int>(kConfig.controlPeriodMs));
  // A whole look around at these limits, then rest. It is longer than the old
  // local glance by design, and longer than kFollowIdleEndMs -- which is why
  // the session holds its idle clock while lookingAround() (camera_stream.ino).
  assert(ticks * kConfig.controlPeriodMs < 30000);
}

// Manual control from the app's joystick.
void manualControl() {
  FollowConfig config;
  config.pitchEnabled = true;
  HeadTracker tracker(kLimits, config);
  uint32_t now = 10000;
  tracker.begin(460, 630, now);

  // Full right: moves right at no more than manualStepRaw per tick.
  assert(tracker.manual(1.0f, 0.0f, now));
  assert(tracker.mode() == FollowMode::Manual);
  int last = tracker.commandedYaw();
  for (int i = 0; i < 3; ++i) {
    now += config.controlPeriodMs;
    tracker.manual(1.0f, 0.0f, now);                  // the app resends while held
    const FollowCommand command = tracker.step(now);
    assert(command.send);
    assert(command.yaw - last > 0 && command.yaw - last <= config.manualStepRaw);
    assert(command.pitch == 630);
    last = command.yaw;
  }

  // A face target while steering is consumed, not acted on.
  assert(!tracker.observe(1, -0.9f, 0.0f, 0.95f, now));
  assert(tracker.mode() == FollowMode::Manual);

  // Small deflection: finer steps than full deflection, but still moves.
  now += config.controlPeriodMs;
  tracker.manual(0.3f, 0.0f, now);
  FollowCommand small = tracker.step(now);
  assert(small.send && small.yaw - last >= 1 && small.yaw - last < config.manualStepRaw);
  last = small.yaw;

  // Up tilts the head up (pitchUpSign +1 means +raw is up).
  now += config.controlPeriodMs;
  tracker.manual(0.0f, 1.0f, now);
  FollowCommand up = tracker.step(now);
  assert(up.send && up.pitch > 630 && up.yaw == last);

  // Held against the limit: clamped, and nothing is sent once it is there.
  for (int i = 0; i < 200; ++i) {
    now += config.controlPeriodMs;
    tracker.manual(1.0f, 0.0f, now);
    const FollowCommand command = tracker.step(now);
    assert(command.yaw <= kLimits.yawMax);
  }
  assert(tracker.commandedYaw() == kLimits.yawMax);

  // Input stops: the head holds still (deadman), and stays in manual for a while.
  const int held = tracker.commandedYaw();
  const uint32_t released = now;
  for (; now < released + config.manualResumeMs - config.controlPeriodMs; now += config.controlPeriodMs) {
    assert(!tracker.step(now).send);
    assert(tracker.commandedYaw() == held);
    assert(!tracker.observe(static_cast<uint32_t>(now), 0.5f, 0.0f, 0.95f, now));
  }

  // Then following resumes from where it was left.
  now = released + config.manualResumeMs + config.controlPeriodMs;
  assert(!tracker.step(now).send);
  assert(tracker.mode() == FollowMode::Idle);
  assert(tracker.observe(900000, -0.5f, 0.0f, 0.95f, now));
  assert(tracker.mode() == FollowMode::Attending);
  assert(tracker.goalYaw() < held);                   // relative to the manual position

  // Garbage is refused.
  assert(!tracker.manual(1.5f, 0.0f, now));
  assert(!tracker.manual(NAN, 0.0f, now));

  // A dead zone at the centre of the stick.
  HeadTracker still(kLimits, config);
  now = 10000;
  still.begin(460, 630, now);
  now += config.controlPeriodMs;
  still.manual(0.05f, -0.05f, now);
  assert(!still.step(now).send);
}

// 2026-09-17: every session was refused because the unpowered head rested at
// pitch 594, 26 below the limit, past the old 24 of slack. That start is now
// accepted, and the session still never tilts the head below it.
void lowPitchRestIsAcceptedAndNeverPushedLower() {
  FollowLimits limits = kLimits;
  limits.pitchStartSlack = 32;
  assert(HeadTracker::pitchStartAcceptable(limits, 594));
  assert(!HeadTracker::pitchStartAcceptable(limits, limits.pitchMin - 33));
  FollowConfig config;
  config.pitchEnabled = true;
  HeadTracker tracker(limits, config);
  uint32_t now = 1000;
  tracker.begin(460, 594, now);
  assert(tracker.pitchLow() == 594 && tracker.commandedPitch() == 594);
  // A face far below centre asks for down: refused by the bounds.
  for (uint32_t sequence = 1; sequence < 40; ++sequence) {
    now += config.controlPeriodMs;
    tracker.observe(sequence, 0.0f, 0.95f, 0.95f, now);
    const FollowCommand command = tracker.step(now);
    assert(command.pitch >= 594);
  }
  // Steering down is refused the same way.
  for (int i = 0; i < 40; ++i) {
    now += config.controlPeriodMs;
    tracker.manual(0.0f, -1.0f, now);
    assert(tracker.step(now).pitch >= 594);
  }
}

// The real limits, from the head's unpowered droop at 594: pitch stays between
// 594 (the unpowered rest; 582 pressed against something) and 870, just short of the stop at
// vertical (~885), and a lost face returns it to level (614, measured
// 2026-09-17), not to the droop.
void measuredPitchLevelFromDroop() {
  const FollowLimits& limits = stanbot::kFollowLimits;
  assert(limits.pitchRestConfirmed && limits.pitchRest == 614);
  assert(HeadTracker::pitchStartAcceptable(limits, 594));
  FollowConfig config;
  config.pitchEnabled = true;
  HeadTracker tracker(limits, config);
  uint32_t now = 1000;
  tracker.begin(460, 594, now);
  assert(tracker.pitchLow() == 594);
  assert(tracker.pitchHigh() == 870);   // just short of vertical
  // A face high in frame: climbs, never past vertical.
  uint32_t sequence = 0;
  for (int i = 0; i < 120; ++i) {
    now += config.controlPeriodMs;
    if (i % 3 == 0) tracker.observe(++sequence, 0.0f, -1.0f, 0.95f, now);
    const FollowCommand command = tracker.step(now);
    assert(command.pitch >= 594 && command.pitch <= 870);
  }
  assert(tracker.commandedPitch() > 630);
  // The face goes: after the search, pitch comes back to level.
  for (int i = 0; i < 200; ++i) {
    now += config.controlPeriodMs;
    tracker.step(now);
  }
  assert(std::abs(tracker.commandedPitch() - 614) < config.deadbandRaw);
  // Held full down on the pad: reaches the rest, 594, and stops there.
  for (int i = 0; i < 400; ++i) {
    now += config.controlPeriodMs;
    tracker.manual(0.0f, -1.0f, now);
    const FollowCommand command = tracker.step(now);
    assert(command.pitch >= 594);
  }
  assert(tracker.commandedPitch() == 594);
}

// The wake scan: one look around the whole allowed range and home again, never
// outside the limits, over in good time; a face ends it at once and says so.
void wakeScanLooksAroundWithinLimits() {
  const FollowLimits& limits = stanbot::kFollowLimits;
  FollowConfig config;
  config.pitchEnabled = true;
  HeadTracker tracker(limits, config);
  uint32_t now = 1000;
  tracker.begin(limits.yawRest, 614, now);
  tracker.beginScan(now);
  assert(tracker.scanning());
  int lowestYaw = limits.yawRest, highestYaw = limits.yawRest, lowestPitch = 614, highestPitch = 614;
  uint32_t finishedAt = 0;
  for (int i = 0; i < 2000; ++i) {
    now += config.controlPeriodMs;
    const FollowCommand command = tracker.step(now);
    assert(command.yaw >= limits.yawMin && command.yaw <= limits.yawMax);
    assert(command.pitch >= tracker.pitchLow() && command.pitch <= tracker.pitchHigh());
    if (command.yaw < lowestYaw) lowestYaw = command.yaw;
    if (command.yaw > highestYaw) highestYaw = command.yaw;
    if (command.pitch < lowestPitch) lowestPitch = command.pitch;
    if (command.pitch > highestPitch) highestPitch = command.pitch;
    if (finishedAt == 0 && !tracker.scanning() && tracker.mode() == FollowMode::Idle) finishedAt = now;
  }
  std::printf("  wake scan reached yaw %d..%d (limits %d..%d), pitch %d..%d\n", lowestYaw, highestYaw,
              limits.yawMin, limits.yawMax, lowestPitch, highestPitch);
  // Both sides, to within the controller's deadband of each limit.
  assert(lowestYaw <= limits.yawMin + config.deadbandRaw && highestYaw >= limits.yawMax - config.deadbandRaw);
  assert(highestPitch >= 614 + 60 && lowestPitch <= tracker.pitchLow() + config.deadbandRaw);  // up, then down
  assert(finishedAt != 0 && finishedAt - 1000 < 25000);                   // and home, in good time
  assert(std::abs(tracker.commandedYaw() - limits.yawRest) < config.deadbandRaw + 1);
  assert(!tracker.takeFoundDuringScan());                                 // nobody was there
  std::printf("  wake scan: %.1f s, yaw %d..%d, pitch %d..%d\n", (finishedAt - 1000) / 1000.0,
              lowestYaw, highestYaw, lowestPitch, highestPitch);

  // A face part way through: the scan stops there, and reports it once.
  HeadTracker found(limits, config);
  now = 1000;
  found.begin(limits.yawRest, 614, now);
  found.beginScan(now);
  for (int i = 0; i < 60; ++i) { now += config.controlPeriodMs; found.step(now); }
  assert(found.scanning());
  assert(found.observe(1, 0.3f, 0.0f, 0.95f, now, now));
  assert(!found.scanning() && found.mode() == FollowMode::Attending);
  assert(found.takeFoundDuringScan());
  assert(!found.takeFoundDuringScan());   // once
  // An ordinary search finding the face is not a scan finding it.
  assert(found.observe(2, 0.1f, 0.0f, 0.95f, now + 50, now + 50));
  assert(!found.takeFoundDuringScan());
}

int main() {
  wakeScanLooksAroundWithinLimits();
  measuredPitchLevelFromDroop();
  lowPitchRestIsAcceptedAndNeverPushedLower();
  manualControl();
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
  pitchFollowsUpAndDown();
  pitchUpTravelIsBoundedFromStart();
  lowRestIsNeverPressedLower();
  lostTargetReturnsPitchToSessionStart();
  pitchStartAcceptance();
  pitchClosedLoopSettles();
  easingRampsUpAndSlowsDown();
  easingRestartsFromRestOnReversal();
  searchGlancesFirstThenLooksAroundEverything();
  searchStartsLeftWhenTheFaceLeftLeft();
  searchEndsWhenTheFaceReturns();
  aGlanceIsOftenTheWholeSearch();
  searchLooksUpAndDown();
  searchNeverMovesDisabledPitch();
  searchIsClampedAndFinite();
  std::printf("head tracker: all tests passed\n");
}
