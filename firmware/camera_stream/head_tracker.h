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
  // Pitch travel is bounded per session, relative to where the head was found
  // resting, because no fixed rest position has been confirmed by eye. A
  // session may tilt up by at most pitchUpTravel from its start, and down no
  // further than the lower of its start and the down-side limit. So a head
  // resting below 620 is never pushed further down, and one resting tilted up
  // may still come down to 620.
  int pitchUpTravel = 32;             // raw above the session start, never more
  // A start this far past the down-side limit is still accepted. 24 refused
  // every session on 2026-09-17: unpowered, the head rested at 594, 26 below.
  // Safe to allow, because a session never pushes pitch below where it started.
  int pitchStartSlack = 32;
  bool pitchRestConfirmed = false;    // true: a lost target returns pitch to pitchRest, not the session start
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
//    before it becomes the position a lost target returns to. Until then
//    (pitchRestConfirmed false) a lost target returns pitch to where the
//    session found it, and travel is bounded relative to that start. Unpowered
//    rests seen so far: 601, 620, 621, 639, 640.
//  - yaw travel starts at half the +-288 the 2026-09-15 sweep traversed.
//  - gains and hunting remain untested: every follow session so far aborted
//    before settling, so rawPerUnitX/Y are still guesses.
//
// A calibration build (STANBOT_FOLLOW_CALIBRATION=1 firmware/build.sh) is the
// only way `measured` becomes true before the checklist is done. It narrows yaw
// to centre +-48 per checklist step 1 and comes from a committed tree, so V
// reports its commit and follow_limits_measured:true, and the app flags it.
// The pitch limits, shared by both builds; measured below.
constexpr int kFollowPitchMin = 594;
constexpr int kFollowPitchMax = 870;
// Yaw centre, MEASURED 2026-09-17 by eye, the way pitch level was. 460 is the
// BSP's defaultZeroPos for servo 1 and was taken on trust; it is 29 raw (9 deg)
// to the robot's right of where the head actually sits square over the feet.
// The symptoms fit exactly: at rest the head sat to the owner's left, and the
// wake scan, sweeping centre +-96, reached 125 raw to their left but only 67 to
// their right, which is why it never came round to them. Two independent
// steered readings agreed (431 and 432, `tools/read_steered_yaw.py`); a third
// at 471 came from a three-input nudge held 0.2 s and was discarded.
// The limits below are written around this, so they move with it.
constexpr int kFollowYawCentre = 431;
#if defined(STANBOT_FOLLOW_CALIBRATION) && STANBOT_FOLLOW_CALIBRATION
// Checklist step 4 widens yaw one supervised session at a time without editing
// source: STANBOT_FOLLOW_YAW_RANGE=96 firmware/build.sh, then 144, 192, 240,
// 288. The robot reports the range in V. Anything else fails to compile.
#if defined(STANBOT_FOLLOW_YAW_RANGE) && STANBOT_FOLLOW_YAW_RANGE
constexpr int kFollowYawRange = STANBOT_FOLLOW_YAW_RANGE;
#else
constexpr int kFollowYawRange = 48;
#endif
// The calibration build halves pitch travel for the first sessions that power it.
// Pitch level MEASURED 2026-09-17 by eye with find_pitch_level.py: raw 634
// tilted up, 614 level (calibration-pitch-level.jsonl). Up: 870, just short of
// vertical. Steered all the way up on 2026-09-17, the head met a hard stop at
// raw ~885 (stall_detected, goal 902), which the operator saw as vertical: 271
// raw for 90 deg, so this servo is ~3.0 raw/deg, not the yaw servo's 3.2. The
// 15 raw of margin keeps steering from grinding into the stop. Down: widened in
// supervised steps. 582 was tried on 2026-09-17: held full down, the head
// stopped at 592 and stayed 10 short of the goal (pressing against something),
// and the owner saw it facing nearly straight down. So the minimum is 594, the
// unpowered rest: a session never presses the head below where gravity leaves it.
// "Nearly straight down" at 592 does not fit ~3 raw/deg from a level of 614,
// so level itself is due a re-check before any further pitch change.
constexpr FollowLimits kFollowLimits = {
  kFollowYawCentre - kFollowYawRange, kFollowYawCentre + kFollowYawRange, kFollowYawCentre,
  kFollowPitchMin, kFollowPitchMax, 614,
  +1, true,
  320, 32, true};
#else
constexpr int kFollowYawRange = 144;
constexpr FollowLimits kFollowLimits = {
  kFollowYawCentre - kFollowYawRange, kFollowYawCentre + kFollowYawRange, kFollowYawCentre,
  kFollowPitchMin, kFollowPitchMax, 614,
  +1, false,
  320, 32, true};
#endif
// 288 is what the 2026-09-15 sweep traversed; nothing wider has been observed.
static_assert(kFollowYawRange >= 48 && kFollowYawRange <= 288 && kFollowYawRange % 48 == 0,
              "STANBOT_FOLLOW_YAW_RANGE must be 48, 96, 144, 192, 240 or 288");

// Pitch follows only in a build made with STANBOT_FOLLOW_PITCH=1. It has
// never been powered through a follow session. On 2026-09-15 a "yaw-only"
// session still drove pitch, because return-to-rest moved both axes; with this
// false the pitch servo is never commanded, never clamped and never given
// torque, so it stays exactly as it is at rest. V reports which build this is.
#if defined(STANBOT_FOLLOW_PITCH) && STANBOT_FOLLOW_PITCH
constexpr bool kFollowPitchEnabled = true;
#else
constexpr bool kFollowPitchEnabled = false;
#endif

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

  // Easing. Fixed steps start and stop abruptly, which reads as mechanical.
  // With easing each tick moves a fraction of the remaining distance (slowing
  // into the goal, never below easeMinStepRaw) and may grow by at most
  // easeAccelRaw over the previous tick (speeding up out of rest). The step
  // limits above stay the ceilings, so nothing gets faster than before.
  bool ease = true;
  float easeFraction = 0.4f;
  int easeMinStepRaw = 2;
  int easeAccelRaw = 2;

  // Search. When the target times out the head does not go straight home: it
  // holds still briefly (the face may simply have been missed), then looks
  // around the whole allowed range for the person -- left, right, up, down --
  // and only returns to rest when that finds nobody. Any accepted observation
  // ends the search immediately. Every waypoint is clamped to the limits and
  // the session's pitch bounds.
  //
  // It used to glance 32 raw toward the side the face left on and 32 the other
  // way, which at the old +-96 limits was most of the range anyway. At +-288 a
  // glance that size is a twitch, and the owner asked for the full look: "I
  // expect it to do the full scan when it loses me. Only if it can't find me
  // should it go back to center and rest." So a search and the wake scan are
  // now the same motion, and differ only in what happens on finding someone.
  bool search = true;
  uint32_t searchHoldMs = 600;       // a beat first: the face may simply have been missed
  uint32_t searchDwellMs = 400;      // pause at each waypoint, to give detection a chance
  int searchGlanceRaw = 32;          // the glance: yaw each side of where they were lost
  int searchGlancePitchRaw = 12;     // and up or down, if they left off the top or bottom
  // The look around itself, shared by a search and the wake scan (beginScan).
  int scanStepRaw = 10;              // ~39 deg/s: brisk, well under the 58 the sweep ran at
  int scanPitchUpRaw = 90;           // how far above level the upward look goes
  uint32_t scanHoldMs = 300;         // a beat before the first turn

  // Manual control, from the app's joystick (H lines). Full deflection moves
  // manualStepRaw per tick, about 15 deg/s: calm, like the rest. Deflection is
  // squared, so small movements of the stick give fine positioning. If H lines
  // stop for manualHoldMs the head holds still (a dropped link never keeps it
  // moving); manualResumeMs after the last one, following resumes from there.
  int manualStepRaw = 4;
  uint32_t manualHoldMs = 300;
  uint32_t manualResumeMs = 1500;
};

// Numbered as reported in telemetry ("mode"); append, never renumber.
enum class FollowMode { Idle, Attending, Returning, Searching, Manual };

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
  int yawAt(uint32_t whenMs) const { return sampleAt(whenMs, yaw_).yaw; }
  // The same for pitch: it has the same frame delay, so it needs the same
  // compensation or it hunts the way yaw did in session 5.
  int pitchAt(uint32_t whenMs) const { return sampleAt(whenMs, pitch_).pitch; }

  // Whether pitch may start a session at this raw position: inside the limits,
  // or resting at most pitchStartSlack past the down-side one. Rests of 601
  // and 594 have been observed, below the BSP's 0 degrees at 620.
  static bool pitchStartAcceptable(const FollowLimits& limits, int position) {
    if (limits.pitchUpSign > 0)
      return position >= limits.pitchMin - limits.pitchStartSlack && position <= limits.pitchMax;
    return position >= limits.pitchMin && position <= limits.pitchMax + limits.pitchStartSlack;
  }

  void begin(int yawNow, int pitchNow, uint32_t nowMs) {
    yaw_ = goalYaw_ = clamp(yawNow, limits_.yawMin, limits_.yawMax);
    // A disabled pitch is left exactly where it is: clamping it would make the
    // commanded position differ from the real one, which is itself a move.
    if (config_.pitchEnabled) {
      const int slack = limits_.pitchStartSlack;
      const int start = limits_.pitchUpSign > 0 ? clamp(pitchNow, limits_.pitchMin - slack, limits_.pitchMax)
                                                : clamp(pitchNow, limits_.pitchMin, limits_.pitchMax + slack);
      // Up is bounded by the travel allowance and the limit; down by the lower
      // of the start and the down-side limit, so a low rest is never pressed lower.
      if (limits_.pitchUpSign > 0) {
        pitchLow_ = start < limits_.pitchMin ? start : limits_.pitchMin;
        pitchHigh_ = start + limits_.pitchUpTravel < limits_.pitchMax ? start + limits_.pitchUpTravel : limits_.pitchMax;
        if (pitchHigh_ < start) pitchHigh_ = start;
      } else {
        pitchHigh_ = start > limits_.pitchMax ? start : limits_.pitchMax;
        pitchLow_ = start - limits_.pitchUpTravel > limits_.pitchMin ? start - limits_.pitchUpTravel : limits_.pitchMin;
        if (pitchLow_ > start) pitchLow_ = start;
      }
      pitchHome_ = start;
      pitch_ = goalPitch_ = start;
    } else {
      pitch_ = goalPitch_ = pitchHome_ = pitchLow_ = pitchHigh_ = pitchNow;
    }
    mode_ = FollowMode::Idle;
    lastControlMs_ = nowMs - config_.controlPeriodMs;
    lastTargetMs_ = 0;
    haveGoal_ = false;
    lastStepYaw_ = lastStepPitch_ = 0;
    lastX_ = lastY_ = 0.0f;
    waypoint_ = waypointCount_ = 0;
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
    if (inManual(nowMs)) return false;   // the person steering wins; consumed, not queued
    if (confidence < config_.confidenceToAttend) return false;
    if (scanning()) foundDuringScan_ = true;   // the look around found someone
    scanning_ = false;
    lastTargetMs_ = nowMs;
    // -1 is the left of the image; +1 raw is robot-right on the yaw servo.
    // -1 is the top of the image, so the head tilts up for negative y.
    const int dx = (x > config_.centreDeadband || x < -config_.centreDeadband)
                       ? roundToInt(x * config_.rawPerUnitX * config_.gain) : 0;
    const int dy = config_.pitchEnabled && (y > config_.centreDeadband || y < -config_.centreDeadband)
                       ? roundToInt(-y * config_.rawPerUnitY * config_.gain) * limits_.pitchUpSign : 0;
    lastX_ = x;
    lastY_ = y;
    goalYaw_ = clamp(yawAt(capturedMs) + dx, limits_.yawMin, limits_.yawMax);
    goalPitch_ = config_.pitchEnabled ? clamp(pitchAt(capturedMs) + dy, pitchLow_, pitchHigh_) : pitch_;
    haveGoal_ = true;
    mode_ = FollowMode::Attending;
    return true;
  }

  // Joystick deflection, each in [-1, 1]: +x turns to the robot's right, +y
  // tilts the head up. Returns whether it was accepted.
  bool manual(float x, float y, uint32_t nowMs) {
    if (!(x == x) || !(y == y) || x < -1.0f || x > 1.0f || y < -1.0f || y > 1.0f) return false;
    manual_ = true;
    manualMs_ = nowMs;
    manualX_ = x;
    manualY_ = y;
    mode_ = FollowMode::Manual;
    haveGoal_ = false;
    lastStepYaw_ = lastStepPitch_ = 0;
    return true;
  }

  bool inManual(uint32_t nowMs) const { return manual_ && nowMs - manualMs_ < config_.manualResumeMs; }

  FollowCommand step(uint32_t nowMs) {
    if (nowMs - lastControlMs_ < config_.controlPeriodMs) return {false, yaw_, pitch_, mode_};
    lastControlMs_ = nowMs;
    if (manual_) {
      if (nowMs - manualMs_ >= config_.manualResumeMs) {
        // Let go long enough: back to following, from wherever the head is now.
        manual_ = false;
        mode_ = FollowMode::Idle;
        haveGoal_ = false;
        return {false, yaw_, pitch_, mode_};
      }
      if (nowMs - manualMs_ >= config_.manualHoldMs) return {false, yaw_, pitch_, mode_};   // no input: hold
      const int dy = manualStep(manualX_);
      const int dp = config_.pitchEnabled ? manualStep(manualY_) * limits_.pitchUpSign : 0;
      const int nextYaw = clamp(yaw_ + dy, limits_.yawMin, limits_.yawMax);
      const int nextPitch = config_.pitchEnabled ? clamp(pitch_ + dp, pitchLow_, pitchHigh_) : pitch_;
      if (nextYaw == yaw_ && nextPitch == pitch_) return {false, yaw_, pitch_, mode_};
      yaw_ = nextYaw;
      pitch_ = nextPitch;
      record(nowMs);
      return {true, yaw_, pitch_, mode_};
    }
    if (mode_ == FollowMode::Attending && nowMs - lastTargetMs_ >= config_.targetTimeoutMs) {
      if (config_.search) beginSearch(nowMs);
      else beginReturn();
    }
    int stepLimit = config_.maxStepRaw;
    if (mode_ == FollowMode::Returning) stepLimit = config_.restStepRaw;
    if (mode_ == FollowMode::Searching) {
      stepLimit = config_.scanStepRaw;
      if (!advanceSearch(nowMs)) return {false, yaw_, pitch_, mode_};
    }
    if (mode_ != FollowMode::Searching) scanning_ = false;   // the scan has handed over
    if (mode_ == FollowMode::Idle || !haveGoal_) return {false, yaw_, pitch_, mode_};

    int dy = goalYaw_ - yaw_;
    int dp = config_.pitchEnabled ? goalPitch_ - pitch_ : 0;
    // A residual inside the raw deadband is accepted as arrived rather than
    // re-issued; this is the rule that stops the loop hunting on I = 0.
    if (dy > -config_.deadbandRaw && dy < config_.deadbandRaw) dy = 0;
    if (dp > -config_.deadbandRaw && dp < config_.deadbandRaw) dp = 0;
    if (dy == 0 && dp == 0) {
      haveGoal_ = false;
      lastStepYaw_ = lastStepPitch_ = 0;
      if (mode_ == FollowMode::Returning) mode_ = FollowMode::Idle;
      if (mode_ == FollowMode::Searching) arrivedMs_ = nowMs;
      return {false, yaw_, pitch_, mode_};
    }
    const int stepYaw = nextStep(dy, stepLimit, lastStepYaw_);
    const int stepPitch = nextStep(dp, stepLimit, lastStepPitch_);
    yaw_ += stepYaw;
    pitch_ += stepPitch;
    lastStepYaw_ = stepYaw;
    lastStepPitch_ = stepPitch;
    record(nowMs);
    return {true, yaw_, pitch_, mode_};
  }

  int commandedYaw() const { return yaw_; }
  // Where the latest observation asked the head to go.
  int goalYaw() const { return goalYaw_; }
  int goalPitch() const { return goalPitch_; }
  int commandedPitch() const { return pitch_; }
  // This session's pitch bounds, for the firmware's feedback envelope.
  int pitchLow() const { return pitchLow_; }
  int pitchHigh() const { return pitchHigh_; }
  int pitchHome() const { return pitchHome_; }
  FollowMode mode() const { return mode_; }

  // One look around on waking: to the left limit, the right limit, back to
  // centre and up, then down, then home. Every waypoint is inside the session's
  // limits. Any accepted observation ends it at once, as it does a search.
  void beginScan(uint32_t nowMs) {
    // No one has been lost, so there is nothing to glance at: straight to the
    // whole range. The wake scan always starts robot-left.
    waypointCount_ = layOutLookAround(-1, 0);
    mode_ = FollowMode::Searching;
    scanning_ = true;
    foundDuringScan_ = false;
    searchStartMs_ = nowMs;
    arrivedMs_ = 0;
    waypoint_ = 0;
    haveGoal_ = false;
  }

  // One look around the whole allowed range, written from slot `n`: the far
  // side `first` names, then the other, then up and down at rest. Returns the
  // new waypoint count. Shared by the wake scan and by the second stage of a
  // search.
  unsigned layOutLookAround(int first, unsigned n) {
    const int level = !config_.pitchEnabled ? pitch_
                    : limits_.pitchRestConfirmed ? clamp(limits_.pitchRest, pitchLow_, pitchHigh_) : pitchHome_;
    const int up = clamp(level + limits_.pitchUpSign * config_.scanPitchUpRaw, pitchLow_, pitchHigh_);
    const int down = limits_.pitchUpSign > 0 ? pitchLow_ : pitchHigh_;
    waypoints_[n++] = {first < 0 ? limits_.yawMin : limits_.yawMax, level};
    waypoints_[n++] = {first < 0 ? limits_.yawMax : limits_.yawMin, level};
    waypoints_[n++] = {limits_.yawRest, up};
    waypoints_[n++] = {limits_.yawRest, down};
    return n;
  }

  // True while the wake scan is looking around.
  bool scanning() const { return scanning_ && mode_ == FollowMode::Searching; }
  // Any look around, a wake scan or a search: the head is actively hunting for
  // someone, so the session must not time out underneath it.
  bool lookingAround() const { return mode_ == FollowMode::Searching; }

  // True once, when a face ended the wake scan: the moment to react.
  bool takeFoundDuringScan() {
    const bool found = foundDuringScan_;
    foundDuringScan_ = false;
    return found;
  }

 private:
  static int clamp(int value, int low, int high) {
    return value < low ? low : (value > high ? high : value);
  }
  static int roundToInt(float value) {
    return static_cast<int>(value >= 0.0f ? value + 0.5f : value - 0.5f);
  }

  // Squared deflection for fine control near the centre of the stick; any
  // deliberate push (past a small dead zone) moves at least one raw step.
  int manualStep(float deflection) const {
    const float magnitude = deflection < 0 ? -deflection : deflection;
    if (magnitude < 0.08f) return 0;
    int step = roundToInt(magnitude * magnitude * config_.manualStepRaw);
    if (step < 1) step = 1;
    return deflection < 0 ? -step : step;
  }

  // Commanded position over the last few seconds, for yawAt() and pitchAt().
  struct Sample { uint32_t ms; int yaw; int pitch; };
  static constexpr unsigned kHistory = 48;
  Sample history_[kHistory] = {};
  unsigned historyStart_ = 0, historyCount_ = 0;

  // One tick's signed step toward a remaining distance `error`.
  int nextStep(int error, int limit, int previous) const {
    if (error == 0) return 0;
    const int magnitude = error < 0 ? -error : error;
    int step = limit;
    if (config_.ease) {
      step = roundToInt(magnitude * config_.easeFraction);
      if (step < config_.easeMinStepRaw) step = config_.easeMinStepRaw;
      if (step > limit) step = limit;
      // Speeding up is bounded by the previous step in the same direction; a
      // reversal starts again from rest.
      const int carried = (previous > 0) == (error > 0) ? (previous < 0 ? -previous : previous) : 0;
      const int ramp = carried + config_.easeAccelRaw;
      if (step > ramp) step = ramp;
    }
    if (step > magnitude) step = magnitude;
    return error < 0 ? -step : step;
  }

  void beginReturn() {
    mode_ = FollowMode::Returning;
    goalYaw_ = limits_.yawRest;
    goalPitch_ = !config_.pitchEnabled ? pitch_
               : limits_.pitchRestConfirmed ? clamp(limits_.pitchRest, pitchLow_, pitchHigh_)
               : pitchHome_;
    haveGoal_ = true;
  }

  // Waypoints for one search, from where the head was when the target was lost
  // and the side of the frame the face was last seen on.
  // Losing the target, in two stages. First a glance either side of where they
  // were lost: someone who leaned out of frame is found in a second or two,
  // and the head barely moves. Only if that finds nobody does it look around
  // the whole allowed range, and only after THAT does it go home. Any accepted
  // observation ends the search wherever it has got to, so the cheap stage
  // usually is the whole search. `scanning_` stays false, so the surprised
  // reaction on finding someone remains the wake scan's alone.
  void beginSearch(uint32_t nowMs) {
    const int side = lastX_ < -config_.centreDeadband ? -1 : 1;   // where they went, if anywhere
    // The glance follows the face off the top or bottom of the frame too.
    int glancePitch = pitch_;
    if (config_.pitchEnabled && (lastY_ > config_.centreDeadband || lastY_ < -config_.centreDeadband)) {
      const int up = lastY_ < 0 ? 1 : -1;
      glancePitch = clamp(pitch_ + up * limits_.pitchUpSign * config_.searchGlancePitchRaw, pitchLow_, pitchHigh_);
    }
    const int lost = yaw_;
    waypoints_[0] = {clamp(lost + side * config_.searchGlanceRaw, limits_.yawMin, limits_.yawMax), glancePitch};
    waypoints_[1] = {clamp(lost - side * config_.searchGlanceRaw, limits_.yawMin, limits_.yawMax), glancePitch};
    waypointCount_ = layOutLookAround(side, 2);
    mode_ = FollowMode::Searching;
    searchStartMs_ = nowMs;
    arrivedMs_ = 0;
    waypoint_ = 0;
    haveGoal_ = false;
  }

  // Returns whether the controller should move this tick.
  bool advanceSearch(uint32_t nowMs) {
    if (nowMs - searchStartMs_ < (scanning_ ? config_.scanHoldMs : config_.searchHoldMs)) return false;   // hold still first
    if (haveGoal_) return true;                                        // still travelling
    if (arrivedMs_ != 0 && nowMs - arrivedMs_ < config_.searchDwellMs) return false;
    if (arrivedMs_ != 0) ++waypoint_;
    arrivedMs_ = 0;
    if (waypoint_ >= waypointCount_) { beginReturn(); return true; }
    goalYaw_ = waypoints_[waypoint_].yaw;
    goalPitch_ = config_.pitchEnabled ? waypoints_[waypoint_].pitch : pitch_;
    haveGoal_ = true;
    return true;
  }

  Sample sampleAt(uint32_t whenMs, int fallback) const {
    if (historyCount_ == 0) return {whenMs, fallback, fallback};
    int best = -1;
    for (unsigned i = 0; i < historyCount_; ++i) {
      const Sample& sample = history_[(historyStart_ + i) % kHistory];
      if (static_cast<int32_t>(whenMs - sample.ms) >= 0) best = static_cast<int>(i);
    }
    if (best < 0) return history_[historyStart_];               // before anything recorded
    return history_[(historyStart_ + static_cast<unsigned>(best)) % kHistory];
  }

  void record(uint32_t nowMs) {
    const unsigned index = (historyStart_ + historyCount_) % kHistory;
    history_[index] = {nowMs, yaw_, pitch_};
    if (historyCount_ < kHistory) ++historyCount_;
    else historyStart_ = (historyStart_ + 1) % kHistory;
  }

  FollowLimits limits_;
  FollowConfig config_;
  int yaw_ = 0, pitch_ = 0;          // last commanded, the controller's own state
  int goalYaw_ = 0, goalPitch_ = 0;  // where the current observation asked to go
  int pitchHome_ = 0, pitchLow_ = 0, pitchHigh_ = 0;  // this session's pitch start and bounds
  int lastStepYaw_ = 0, lastStepPitch_ = 0;           // for easing
  float lastX_ = 0.0f, lastY_ = 0.0f;                 // where the face was last seen, for search
  struct Waypoint { int yaw, pitch; };
  Waypoint waypoints_[6] = {};   // a search: two glances, then the four of a look around
  bool scanning_ = false;
  bool foundDuringScan_ = false;
  unsigned waypoint_ = 0, waypointCount_ = 0;
  uint32_t searchStartMs_ = 0, arrivedMs_ = 0;
  bool haveGoal_ = false;
  FollowMode mode_ = FollowMode::Idle;
  uint32_t lastControlMs_ = 0;
  uint32_t lastTargetMs_ = 0;
  uint32_t lastSequence_ = 0;
  bool manual_ = false;
  uint32_t manualMs_ = 0;
  float manualX_ = 0.0f, manualY_ = 0.0f;
};

}  // namespace stanbot
