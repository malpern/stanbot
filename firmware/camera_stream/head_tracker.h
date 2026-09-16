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

// Starting guards, NOT a calibration. Every number here is a bound the
// firmware refuses to exceed, chosen from what has been observed rather than
// what the BSP permits, and `measured` stays false until each has been checked
// on this unit with a person watching:
//  - yaw: the 2026-09-15 sweep traversed centre +-288 raw (90 degrees each way)
//    smoothly; following starts at half of that.
//  - pitch: only +16 raw (5 degrees) from rest has ever moved. The BSP maps
//    0..90 degrees onto 620..908, so +raw is the only direction inside the
//    official range from rest and -raw is never commanded.
//  - pitchUpSign is a guess. Whether +raw nods up or down is for the operator
//    to observe on the first pitch session, then record here.
constexpr FollowLimits kFollowLimits = {
  460 - 144, 460 + 144, 460,
  620, 620 + 32, 620,
  +1, false};

struct FollowConfig {
  float confidenceToAttend = 0.70f;  // face-detection.md's starting threshold
  uint32_t targetTimeoutMs = 900;    // ignore a target after this, then return to rest
  uint32_t controlPeriodMs = 80;     // one goal update per period at most
  float centreDeadband = 0.08f;      // |x| or |y| below this: already looking at it
  int rawPerUnitX = 96;              // raw steps for a face at the image edge (~30 deg)
  int rawPerUnitY = 64;
  int deadbandRaw = 8;               // never chase less than this: above the standing error
  int maxStepRaw = 6;                // per tick while attending (~23 deg/s at 80 ms)
  int restStepRaw = 4;               // per tick while returning (~16 deg/s)
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
  void begin(int yawNow, int pitchNow, uint32_t nowMs) {
    yaw_ = goalYaw_ = clamp(yawNow, limits_.yawMin, limits_.yawMax);
    pitch_ = goalPitch_ = clamp(pitchNow, limits_.pitchMin, limits_.pitchMax);
    mode_ = FollowMode::Idle;
    lastControlMs_ = nowMs - config_.controlPeriodMs;
    lastTargetMs_ = 0;
    haveGoal_ = false;
  }

  // One T,<seq>,<x>,<y>,<confidence> line. Rejects anything outside the
  // protocol ranges, a repeated or older sequence, and NaN; a rejected line
  // leaves the current goal untouched. Returns whether it was taken up.
  bool observe(uint32_t sequence, float x, float y, float confidence, uint32_t nowMs) {
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
                       ? roundToInt(x * config_.rawPerUnitX) : 0;
    const int dy = (y > config_.centreDeadband || y < -config_.centreDeadband)
                       ? roundToInt(-y * config_.rawPerUnitY) * limits_.pitchUpSign : 0;
    goalYaw_ = clamp(yaw_ + dx, limits_.yawMin, limits_.yawMax);
    goalPitch_ = clamp(pitch_ + dy, limits_.pitchMin, limits_.pitchMax);
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
      goalPitch_ = limits_.pitchRest;
      haveGoal_ = true;
    }
    if (mode_ == FollowMode::Returning) stepLimit = config_.restStepRaw;
    if (mode_ == FollowMode::Idle || !haveGoal_) return {false, yaw_, pitch_, mode_};

    int dy = goalYaw_ - yaw_;
    int dp = goalPitch_ - pitch_;
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
