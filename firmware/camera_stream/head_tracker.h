#pragma once
// Head-following controller: pure logic, shared by the firmware and the native
// boundary tests in companion/test_head_tracker.cpp. Nothing here touches a
// servo, a clock or a serial port; the firmware feeds it observations and time
// and executes the raw goals it hands back inside its own power window.
//
// The design is visual servoing, not absolute mapping. A face at normalized
// x = +0.3 does not mean "point the head at 30% of travel"; it means "turn a
// little further toward the right than you are now". Each accepted observation
// therefore becomes ONE goal relative to the last commanded position, and the
// controller steps toward that goal at a bounded rate until a newer
// observation replaces it or the target times out. Applying an observation
// once is what keeps 3.5 fps of frames from being counted four times by an
// 80 ms control tick.
//
// Two deadbands stop the hunting the servo review predicts (I = 0 leaves a
// 3-6 raw-step standing error that a naive follower would chase forever):
// a centre deadband on the normalized offset, so a face already near the
// middle of the frame asks for nothing, and a raw deadband on the remaining
// travel, so a residual smaller than the standing error is never re-issued.
// Feedback is deliberately not used for control at all; the firmware uses it
// only to guard the envelope and detect a stall.

#include <stdint.h>

namespace stanbot {

struct FollowLimits {
  int yawMin, yawMax, yawRest;        // raw servo units, ID 1
  int pitchMin, pitchMax, pitchRest;  // raw servo units, ID 2
  int pitchUpSign;                    // +1 if +raw tilts the head up, -1 if down
  bool measured;                      // the per-unit calibration checklist is done
};

// Directions below are MEASURED on this unit (2026-09-15, supervised, with the
// operator watching); the travel limits are still guards, and `measured` stays
// false because the checklist is not finished. See docs/head-following.md.
//
//  - yaw: +raw turns the head to the ROBOT's right. Measured, not assumed.
//  - pitch: +raw tilts the head UP, so pitchUpSign is +1. Measured.
//  - image orientation: a person standing on the robot's right appears on the
//    RIGHT of the captured frame, so the image is not mirrored and observe()'s
//    x sign is correct as written. Measured by capturing a frame with the
//    operator at a known side, not inferred from a datasheet.
//  - pitch rest is NOT established. Raw 642 was reported as still tilted up,
//    so level is at or below it; 620 is the BSP's 0 degrees and the candidate,
//    but nothing has ever been observed at 620 and it must be confirmed by eye
//    before it becomes the position a lost target returns to.
//  - yaw travel starts at half the +-288 the 2026-09-15 sweep traversed.
//  - gains and hunting remain untested: every follow session so far aborted
//    before settling, so rawPerUnitX/Y are still guesses.
//
// A calibration build (STANBOT_FOLLOW_CALIBRATION=1 firmware/build.sh) is the
// only way `measured` becomes true before the checklist is done. It narrows yaw
// to centre +-48 per checklist step 1 and comes from a committed tree, so V
// reports its commit and follow_limits_measured:true, and the app flags it.
#if defined(STANBOT_FOLLOW_CALIBRATION) && STANBOT_FOLLOW_CALIBRATION
constexpr FollowLimits kFollowLimits = {
  460 - 48, 460 + 48, 460,
  620, 620 + 32, 620,
  +1, true};
#else
constexpr FollowLimits kFollowLimits = {
  460 - 144, 460 + 144, 460,
  620, 620 + 32, 620,
  +1, false};
#endif

// Pitch stays out of following until its rest position is confirmed by eye.
// On 2026-09-15 a "yaw-only" session still drove pitch, because return-to-rest
// moved both axes; with this false the pitch servo is never commanded, never
// clamped and never given torque, so it stays exactly as it is at rest.
constexpr bool kFollowPitchEnabled = false;

struct FollowConfig {
  float confidenceToAttend = 0.70f;  // face-detection.md's starting threshold
  uint32_t targetTimeoutMs = 900;    // ignore a target after this, then return to rest
  uint32_t controlPeriodMs = 80;     // one goal update per period at most
  float centreDeadband = 0.08f;      // |x| or |y| below this: already looking at it
  int rawPerUnitX = 96;              // raw steps for a face at the image edge (~30 deg)
  int rawPerUnitY = 64;
  // Fraction of the measured error corrected per observation. Below 1 because
  // rawPerUnitX is a guess at the camera's field of view: over-estimating it
  // with a gain of 1 turns every correction into an overshoot.
  float gain = 0.6f;
  int deadbandRaw = 8;               // never chase less than this: above the standing error
  int maxStepRaw = 6;                // per tick while attending (~23 deg/s at 80 ms)
  int restStepRaw = 4;               // per tick while returning (~16 deg/s)
  bool pitchEnabled = true;          // false: yaw only, pitch never commanded (kFollowPitchEnabled)
};

enum class FollowMode { Idle, Attending, Returning };

struct FollowCommand {
  bool send;          // false: nothing to write this tick
  int yaw, pitch;     // absolute raw goals, already clamped to the limits
  FollowMode mode;
};

class HeadTracker {
 public:
  HeadTracker(const FollowLimits& limits, const FollowConfig& config)
      : limits_(limits), config_(config) {}

  // Adopt the measured starting position as the commanded one. The firmware
  // holds this exact goal before enabling torque, so the first tick never
  // yanks the head from wherever it was resting.
  // Where the head was commanded to be at `whenMs`, from the recent history.
  // Older than the history reaches, or empty: the oldest sample, or now.
  int yawAt(uint32_t whenMs) const {
    if (historyCount_ == 0) return yaw_;
    int best = -1;
    for (unsigned i = 0; i < historyCount_; ++i) {
      const Sample& sample = history_[(historyStart_ + i) % kHistory];
      if (static_cast<int32_t>(whenMs - sample.ms) >= 0) best = static_cast<int>(i);
    }
    if (best < 0) return history_[historyStart_].yaw;          // before anything recorded
    return history_[(historyStart_ + static_cast<unsigned>(best)) % kHistory].yaw;
  }

  void begin(int yawNow, int pitchNow, uint32_t nowMs) {
    yaw_ = goalYaw_ = clamp(yawNow, limits_.yawMin, limits_.yawMax);
    // A disabled pitch is left exactly where it is: clamping it would make the
    // commanded position differ from the real one, which is itself a move.
    pitch_ = goalPitch_ = config_.pitchEnabled ? clamp(pitchNow, limits_.pitchMin, limits_.pitchMax) : pitchNow;
    mode_ = FollowMode::Idle;
    lastControlMs_ = nowMs - config_.controlPeriodMs;
    lastTargetMs_ = 0;
    haveGoal_ = false;
    historyCount_ = 0;
    historyStart_ = 0;
    record(nowMs);
  }

  // One T,<seq>,<x>,<y>,<confidence> line. Rejects anything outside the
  // protocol ranges, a repeated or older sequence, and NaN; a rejected line
  // leaves the current goal untouched. Returns whether it was taken up.
  //
  // `capturedMs` is when the frame this target came from was sent, which the
  // firmware looks up from the frame's sequence number. The correction is
  // relative to where the head was pointing THEN, not now. Measured on
  // 2026-09-16: correcting from the current position instead made every frame
  // re-ask for motion that was already under way, and the head hunted across
  // its whole range with a period of about 3 s.
  bool observe(uint32_t sequence, float x, float y, float confidence, uint32_t nowMs) {
    return observe(sequence, x, y, confidence, nowMs, nowMs);
  }

  bool observe(uint32_t sequence, float x, float y, float confidence, uint32_t nowMs, uint32_t capturedMs) {
    if (!(x == x) || !(y == y) || !(confidence == confidence)) return false;
    if (x < -1.0f || x > 1.0f || y < -1.0f || y > 1.0f) return false;
    if (confidence < 0.0f || confidence > 1.0f) return false;
    if (sequence <= lastSequence_) return false;
    lastSequence_ = sequence;
    if (confidence < config_.confidenceToAttend) return false;
    lastTargetMs_ = nowMs;
    // -1 is the left of the image; +1 raw is robot-right on the yaw servo.
    // -1 is the top of the image, so the head tilts up for negative y.
    const int dx = (x > config_.centreDeadband || x < -config_.centreDeadband)
                       ? roundToInt(x * config_.rawPerUnitX * config_.gain) : 0;
    const int dy = config_.pitchEnabled && (y > config_.centreDeadband || y < -config_.centreDeadband)
                       ? roundToInt(-y * config_.rawPerUnitY * config_.gain) * limits_.pitchUpSign : 0;
    goalYaw_ = clamp(yawAt(capturedMs) + dx, limits_.yawMin, limits_.yawMax);
    goalPitch_ = config_.pitchEnabled ? clamp(pitch_ + dy, limits_.pitchMin, limits_.pitchMax) : pitch_;
    haveGoal_ = true;
    mode_ = FollowMode::Attending;
    return true;
  }

  FollowCommand step(uint32_t nowMs) {
    if (nowMs - lastControlMs_ < config_.controlPeriodMs) return {false, yaw_, pitch_, mode_};
    lastControlMs_ = nowMs;
    int stepLimit = config_.maxStepRaw;
    if (mode_ == FollowMode::Attending && nowMs - lastTargetMs_ >= config_.targetTimeoutMs) {
      mode_ = FollowMode::Returning;
      goalYaw_ = limits_.yawRest;
      goalPitch_ = config_.pitchEnabled ? limits_.pitchRest : pitch_;
      haveGoal_ = true;
    }
    if (mode_ == FollowMode::Returning) stepLimit = config_.restStepRaw;
    if (mode_ == FollowMode::Idle || !haveGoal_) return {false, yaw_, pitch_, mode_};

    int dy = goalYaw_ - yaw_;
    int dp = config_.pitchEnabled ? goalPitch_ - pitch_ : 0;
    // A residual inside the raw deadband is accepted as arrived rather than
    // re-issued; this is the rule that stops the loop hunting on I = 0.
    if (dy > -config_.deadbandRaw && dy < config_.deadbandRaw) dy = 0;
    if (dp > -config_.deadbandRaw && dp < config_.deadbandRaw) dp = 0;
    if (dy == 0 && dp == 0) {
      haveGoal_ = false;
      if (mode_ == FollowMode::Returning) mode_ = FollowMode::Idle;
      return {false, yaw_, pitch_, mode_};
    }
    yaw_ += clamp(dy, -stepLimit, stepLimit);
    pitch_ += clamp(dp, -stepLimit, stepLimit);
    record(nowMs);
    return {true, yaw_, pitch_, mode_};
  }

  int commandedYaw() const { return yaw_; }
  int commandedPitch() const { return pitch_; }
  FollowMode mode() const { return mode_; }

 private:
  static int clamp(int value, int low, int high) {
    return value < low ? low : (value > high ? high : value);
  }
  static int roundToInt(float value) {
    return static_cast<int>(value >= 0.0f ? value + 0.5f : value - 0.5f);
  }

  // Commanded yaw over the last few seconds, for yawAt().
  struct Sample { uint32_t ms; int yaw; };
  static constexpr unsigned kHistory = 48;
  Sample history_[kHistory] = {};
  unsigned historyStart_ = 0, historyCount_ = 0;

  void record(uint32_t nowMs) {
    const unsigned index = (historyStart_ + historyCount_) % kHistory;
    history_[index] = {nowMs, yaw_};
    if (historyCount_ < kHistory) ++historyCount_;
    else historyStart_ = (historyStart_ + 1) % kHistory;
  }

  FollowLimits limits_;
  FollowConfig config_;
  int yaw_ = 0, pitch_ = 0;          // last commanded, the controller's own state
  int goalYaw_ = 0, goalPitch_ = 0;  // where the current observation asked to go
  bool haveGoal_ = false;
  FollowMode mode_ = FollowMode::Idle;
  uint32_t lastControlMs_ = 0;
  uint32_t lastTargetMs_ = 0;
  uint32_t lastSequence_ = 0;
};

}  // namespace stanbot
