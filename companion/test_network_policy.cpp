// c++ -std=c++17 companion/test_network_policy.cpp -o /tmp/test_network_policy && /tmp/test_network_policy
#include "../firmware/camera_stream/network_policy.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>

using stanbot::networkCommandAllowed;

int main() {
  // What the companion sends over Wi-Fi must keep working.
  for (const char* ok : {"S", "X", "V", "P", "Z", "E,happy", "T,12,0.1,-0.2,0.9",
                         "R,200", "M,320", "M,raw320", "J,90", "C,UNFOLLOW", "C,SLEEP", "C,WAKE", "G,0.1,-0.2", "H,5,0.5,-0.25",
                         "K,lsy=431,lsp=614", "K,"}) {
    assert(networkCommandAllowed(ok));
  }
  // Provisioning, motion, reboot and the servo bus stay USB-only.
  for (const char* refused : {"W,O,newpassphrase", "W,S,0,evil", "W,P,0,x", "W,X", "W,GO",
                              "W,?", "W,SCAN", "W,N,1", "C,REBOOT", "C,FOLLOW", "C,YAWSWEEP",
                              "C,CENTER", "C,PITCHNUDGE", "C,POWERTEST", "Q", "C,OFF", "C,SLEEPX",
                              "A,FOLLOW,00", "A,?", "C,UNFOLLOWX"}) {
    assert(!networkCommandAllowed(refused));
  }
  // Near misses must not slip through on a prefix or a loose match.
  for (const char* odd : {"", "s", "SS", "VV", "S ", " S", "E", "EX", "W", "C", "Q,", "X,W,O,1",
                          "P,C,REBOOT"}) {
    assert(!networkCommandAllowed(odd));
  }
  assert(!networkCommandAllowed(nullptr));
  std::puts("network policy: all checks passed");
}
