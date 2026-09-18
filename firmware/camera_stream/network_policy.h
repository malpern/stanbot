#pragma once
#include <cstring>

namespace stanbot {

// Which newline commands a Wi-Fi viewer may send. Pure, so it is tested
// natively by companion/test_network_policy.cpp.
//
// An allowlist, not a denylist: a command added later is USB-only until
// someone decides otherwise here. Allowed are the stream and display controls
// the companion needs over Wi-Fi. Refused are provisioning (W,: Wi-Fi profiles
// and the OTA passphrase), motion and reboot (C,), and the servo probe (Q).
// Without this, anyone who could reach port 3333 could set a new OTA
// passphrase, which made the passphrase worthless. See docs/transport.md.
inline bool networkCommandAllowed(const char* line) {
  if (line == nullptr) return false;
  // C,UNFOLLOW only ever makes the robot safer, so it needs no authorization.
  // Starting a session or rebooting over Wi-Fi goes through command_auth.h.
  // C,SLEEP and C,WAKE only darken or restore the screen and stop or allow the
  // stream, which X and S already do; turning the robot OFF is not here,
  // because only its button can undo that (command_auth.h).
  // C,MOUTH,... only chooses how the mouth is drawn: a display change, like E,
  // and G,, and it exists to be switched while watching the robot.
  // C,SCREEN only reads back the picture the robot is already drawing -- the
  // same face the viewer can see -- so it moves nothing and reveals nothing the
  // viewer does not already have. It is allowed over Wi-Fi deliberately:
  // checking a face change without standing in front of the robot is the whole
  // point of it (2026-09-18).
  static const char* const exact[] = {"S", "X", "V", "P", "Z", "C,UNFOLLOW", "C,SLEEP", "C,WAKE",
                                      "C,MOUTH,CAPSULE", "C,MOUTH,GRILLE", "C,SCREEN"};
  for (const char* command : exact) {
    if (strcmp(line, command) == 0) return true;
  }
  // Two-character prefixes whose payload can do no more than the exact
  // commands above: expression, follow target, frame interval, image mode,
  // JPEG quality, eye gaze. T, is only consumed inside C,FOLLOW, which is
  // USB-only; G, moves only the pupils drawn on the display.
  // H, is the app's joystick: like T, it only acts inside a follow session,
  // and starting one over Wi-Fi needs the passphrase (command_auth.h).
  // K, is state the Mac kept for the robot across a reset (last seen place).
  // It moves nothing: every value is clamped to the follow limits on arrival
  // and only biases where a look around begins, inside a session the app
  // already needs the passphrase to start.
  static const char* const prefixes[] = {"E,", "T,", "H,", "R,", "M,", "J,", "G,", "K,"};
  for (const char* prefix : prefixes) {
    if (strncmp(line, prefix, 2) == 0) return true;
  }
  return false;
}

}  // namespace stanbot
