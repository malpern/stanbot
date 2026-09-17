#include "../firmware/camera_stream/pitch_level.h"
#include "../firmware/camera_stream/network_policy.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>

int main() {
  int raw = 0;
  assert(stanbot::parsePitchLevel("620", raw) && raw == 620);
  assert(stanbot::parsePitchLevel("596", raw) && raw == 596);
  assert(stanbot::parsePitchLevel("672", raw) && raw == 672);
  for (const char* bad : {"595", "673", "", "-620", "+620", " 620", "620 ", "620x", "6.2e2", "abc", "99999999999"}) {
    raw = 1;
    assert(!stanbot::parsePitchLevel(bad, raw));
    assert(raw == 1);
  }
  assert(!stanbot::parsePitchLevel(nullptr, raw));
  // Motion: never allowed from a Wi-Fi viewer.
  assert(!stanbot::networkCommandAllowed("C,PITCHLEVEL,620"));
  std::printf("pitch level: all tests passed\n");
}
