#include "../firmware/lib/StanbotEyes/src/MouthModel.h"
#include <cassert>
#include <cstdio>

using stanbot::MouthModel;

static void runFor(MouthModel& mouth, uint32_t& now, uint32_t ms) {
  for (uint32_t t = 0; t < ms; t += 33) { now += 33; mouth.update(now); }
}

static uint8_t packet[11];
static const uint8_t* makePacket(uint8_t version, uint8_t open, int8_t shape, uint32_t sequence) {
  memcpy(packet, "SBMO", 4);
  packet[4] = version;
  packet[5] = open;
  packet[6] = static_cast<uint8_t>(shape);
  for (int i = 0; i < 4; ++i) packet[7 + i] = static_cast<uint8_t>(sequence >> (8 * i));
  return packet;
}

void parsesOnlyWellFormedPackets() {
  uint32_t sequence = 0;
  uint8_t open = 0;
  int8_t shape = 0;
  assert(stanbot::parseMouthPacket(makePacket(2, 55, -40, 0x01020304), 11, sequence, open, shape));
  assert(open == 55 && shape == -40 && sequence == 0x01020304);
  assert(!stanbot::parseMouthPacket(makePacket(2, 55, 0, 1), 10, sequence, open, shape));     // short
  assert(!stanbot::parseMouthPacket(makePacket(1, 55, 0, 1), 11, sequence, open, shape));     // old version
  assert(!stanbot::parseMouthPacket(makePacket(2, 101, 0, 1), 11, sequence, open, shape));    // opening range
  assert(!stanbot::parseMouthPacket(makePacket(2, 50, -101, 1), 11, sequence, open, shape));  // shape range
  makePacket(2, 10, 0, 1);
  packet[0] = 'X';
  assert(!stanbot::parseMouthPacket(packet, 11, sequence, open, shape));                      // magic
  assert(!stanbot::parseMouthPacket(nullptr, 11, sequence, open, shape));
}

void restsAsAThinLine() {
  MouthModel mouth;
  uint32_t now = 1000;
  mouth.update(now);
  runFor(mouth, now, 2000);
  const auto rest = mouth.shape();
  assert(rest.width == 40 && rest.height == 4);   // always drawn, never gone
  assert(rest.innerWidth == 0 && rest.innerHeight == 0);
}

void opensWithLoudnessAndShapesWithTheVoice() {
  MouthModel mouth;
  uint32_t now = 1000;
  mouth.update(now);
  uint32_t seq = 0;
  auto hold = [&](uint8_t open, int8_t shape, int packets) {
    for (int i = 0; i < packets; ++i) { assert(mouth.receive(++seq, open, shape, now)); runFor(mouth, now, 66); }
  };
  hold(100, 0, 6);   // "ah": tall, corners drawn in
  auto ah = mouth.shape();
  assert(ah.height >= 21 && ah.width <= 35 && ah.innerHeight > 0);
  hold(60, 100, 6);  // "ee": wide and flat
  auto ee = mouth.shape();
  assert(ee.width > 46 && ee.height < ah.height);
  hold(60, -100, 8); // "oo": narrow and round
  auto oo = mouth.shape();
  assert(oo.width < 30 && oo.height > ee.height);
  assert(mouth.opening() >= 0.0f && mouth.opening() <= 1.0f);
  assert(mouth.shapeValue() >= -1.0f && mouth.shapeValue() <= 1.0f);
}

void returnsToTheLineWhenPacketsStop() {
  MouthModel mouth;
  uint32_t now = 1000;
  mouth.update(now);
  mouth.receive(1, 100, 80, now);
  runFor(mouth, now, 300);
  assert(mouth.opening() > 0.5f);
  // The link drops with no final packet: back to the resting line within a second.
  runFor(mouth, now, 1000);
  const auto rest = mouth.shape();
  assert(rest.width == 40 && rest.height == 4);
}

void staleAndRepeatedSequencesAreIgnored() {
  MouthModel mouth;
  uint32_t now = 1000;
  assert(mouth.receive(10, 50, 0, now));
  assert(!mouth.receive(10, 90, 0, now));   // repeat
  assert(!mouth.receive(9, 90, 0, now));    // late
  assert(mouth.receive(11, 60, 0, now));
  assert(mouth.receive(5000, 60, 0, now));
  assert(!mouth.receive(4990, 60, 0, now)); // a little behind: late
  assert(mouth.receive(1, 60, 0, now));     // far behind: the app restarted its count
  assert(!mouth.receive(1, 60, 0, now + 1000));
  assert(mouth.receive(1, 60, 0, now + 2500));   // after a long silence: a fresh start
}

void stalledLoopDoesNotFlingTheSprings() {
  MouthModel mouth;
  uint32_t now = 1000;
  mouth.update(now);
  mouth.receive(1, 100, -100, now);
  now += 350;
  mouth.update(now);
  assert(mouth.opening() >= 0.0f && mouth.opening() <= 1.0f);
  assert(mouth.shapeValue() >= -1.0f && mouth.shapeValue() <= 1.0f);
}

int main() {
  parsesOnlyWellFormedPackets();
  restsAsAThinLine();
  opensWithLoudnessAndShapesWithTheVoice();
  returnsToTheLineWhenPacketsStop();
  staleAndRepeatedSequencesAreIgnored();
  stalledLoopDoesNotFlingTheSprings();
  std::puts("mouth model: all tests passed");
  return 0;
}
