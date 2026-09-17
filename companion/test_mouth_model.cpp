#include "../firmware/lib/StanbotEyes/src/MouthModel.h"
#include <cassert>
#include <cstdio>

using stanbot::MouthModel;

static void runFor(MouthModel& mouth, uint32_t& now, uint32_t ms) {
  for (uint32_t t = 0; t < ms; t += 33) { now += 33; mouth.update(now); }
}

static uint8_t packet[10];
static const uint8_t* makePacket(uint8_t version, uint8_t value, uint32_t sequence) {
  memcpy(packet, "SBMO", 4);
  packet[4] = version;
  packet[5] = value;
  for (int i = 0; i < 4; ++i) packet[6 + i] = static_cast<uint8_t>(sequence >> (8 * i));
  return packet;
}

void parsesOnlyWellFormedPackets() {
  uint32_t sequence = 0;
  uint8_t value = 0;
  assert(stanbot::parseMouthPacket(makePacket(1, 55, 0x01020304), 10, sequence, value));
  assert(value == 55 && sequence == 0x01020304);
  assert(!stanbot::parseMouthPacket(makePacket(1, 55, 1), 9, sequence, value));    // short
  assert(!stanbot::parseMouthPacket(makePacket(2, 55, 1), 10, sequence, value));   // version
  assert(!stanbot::parseMouthPacket(makePacket(1, 101, 1), 10, sequence, value));  // out of range
  makePacket(1, 10, 1);
  packet[0] = 'X';
  assert(!stanbot::parseMouthPacket(packet, 10, sequence, value));                 // magic
  assert(!stanbot::parseMouthPacket(nullptr, 10, sequence, value));
}

void hiddenUntilSpoken() {
  MouthModel mouth;
  uint32_t now = 1000;
  mouth.update(now);
  runFor(mouth, now, 2000);
  assert(!mouth.shape().visible);
}

void opensGrowsInAndFollowsLoudness() {
  MouthModel mouth;
  uint32_t now = 1000;
  mouth.update(now);
  uint32_t seq = 0;
  // 300 ms of loud speech, a packet every 66 ms.
  for (int i = 0; i < 5; ++i) { assert(mouth.receive(++seq, 100, now)); runFor(mouth, now, 66); }
  const auto open = mouth.shape();
  assert(open.visible);
  assert(mouth.presence() == 1.0f);
  assert(mouth.opening() > 0.9f);
  assert(open.height >= 17 && open.height <= 18 && open.width >= 43 && open.width <= 44);
  assert(open.innerHeight > 0 && open.innerWidth > 0);
  // Never beyond the fully open shape, and never snapping past it.
  for (int i = 0; i < 20; ++i) { mouth.receive(++seq, 100, now); runFor(mouth, now, 66); assert(mouth.opening() <= 1.0f); }
  // Quieter: closes toward a smaller opening, still visible.
  for (int i = 0; i < 6; ++i) { mouth.receive(++seq, 20, now); runFor(mouth, now, 66); }
  assert(mouth.opening() > 0.15f && mouth.opening() < 0.3f);
  assert(mouth.shape().visible);
}

void closesAndDisappearsWhenPacketsStop() {
  MouthModel mouth;
  uint32_t now = 1000;
  mouth.update(now);
  mouth.receive(1, 100, now);
  runFor(mouth, now, 300);
  assert(mouth.opening() > 0.5f);
  // The link drops: no final 0 arrives. Still open just inside the timeout...
  runFor(mouth, now, 60);
  // ...then shut and gone well within a second.
  runFor(mouth, now, 900);
  assert(mouth.opening() < 0.02f);
  assert(!mouth.shape().visible);
}

void finalZeroClosesPromptly() {
  MouthModel mouth;
  uint32_t now = 1000;
  mouth.update(now);
  uint32_t seq = 0;
  for (int i = 0; i < 5; ++i) { mouth.receive(++seq, 80, now); runFor(mouth, now, 66); }
  mouth.receive(++seq, 0, now);
  runFor(mouth, now, 300);
  assert(mouth.opening() < 0.05f);
  runFor(mouth, now, 300);
  assert(!mouth.shape().visible);
}

void staleAndRepeatedSequencesAreIgnored() {
  MouthModel mouth;
  uint32_t now = 1000;
  assert(mouth.receive(10, 50, now));
  assert(!mouth.receive(10, 90, now));   // repeat
  assert(!mouth.receive(9, 90, now));    // late
  assert(mouth.receive(11, 60, now));
  assert(mouth.receive(5000, 60, now));
  assert(!mouth.receive(4990, 60, now));  // a little behind: late
  assert(mouth.receive(1, 60, now));      // far behind: the app restarted its count
  assert(!mouth.receive(1, 60, now + 1000));
  assert(mouth.receive(1, 60, now + 2500));   // after a long silence: a fresh start
}

void stalledLoopDoesNotFlingTheSpring() {
  MouthModel mouth;
  uint32_t now = 1000;
  mouth.update(now);
  mouth.receive(1, 100, now);
  now += 350;   // one long gap, still inside the silence timeout
  mouth.update(now);
  assert(mouth.opening() >= 0.0f && mouth.opening() <= 1.0f);
}

int main() {
  parsesOnlyWellFormedPackets();
  hiddenUntilSpoken();
  opensGrowsInAndFollowsLoudness();
  closesAndDisappearsWhenPacketsStop();
  finalZeroClosesPromptly();
  staleAndRepeatedSequencesAreIgnored();
  stalledLoopDoesNotFlingTheSpring();
  std::puts("mouth model: all tests passed");
  return 0;
}
