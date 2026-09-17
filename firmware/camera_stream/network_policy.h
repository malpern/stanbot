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
  static const char* const exact[] = {"S", "X", "V", "P", "Z", "C,UNFOLLOW"};
  for (const char* command : exact) {
    if (strcmp(line, command) == 0) return true;
  }
  // Two-character prefixes whose payload can do no more than the exact
  // commands above: expression, follow target, frame interval, image mode,
  // JPEG quality, eye gaze. T, is only consumed inside C,FOLLOW, which is
  // USB-only; G, moves only the pupils drawn on the display.
  static const char* const prefixes[] = {"E,", "T,", "R,", "M,", "J,", "G,"};
  for (const char* prefix : prefixes) {
    if (strncmp(line, prefix, 2) == 0) return true;
  }
  return false;
}

}  // namespace stanbot
