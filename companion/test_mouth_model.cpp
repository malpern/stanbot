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

void hiddenUntilSpeechThenGrowsIn() {
  MouthModel mouth;
  uint32_t now = 1000;
  mouth.update(now);
  runFor(mouth, now, 2000);
  assert(!mouth.shape().visible);            // silent: no mouth at all
  mouth.receive(1, 0, 0, now);               // speech starting, still quiet
  now += 33; mouth.update(now);
  const auto growing = mouth.shape();
  assert(growing.visible && growing.width < 40);   // growing in from the centre
  runFor(mouth, now, 200);
  const auto line = mouth.shape();
  assert(line.visible && line.width == 40 && line.height == 4);
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
  // The link drops with no final packet: eases back to the line, then goes.
  runFor(mouth, now, 400);
  assert(mouth.shape().visible);
  runFor(mouth, now, 1000);
  assert(!mouth.shape().visible);
}

void staysThroughShortPauses() {
  MouthModel mouth;
  uint32_t now = 1000;
  mouth.update(now);
  uint32_t seq = 0;
  for (int i = 0; i < 6; ++i) { mouth.receive(++seq, 70, 0, now); runFor(mouth, now, 66); }
  runFor(mouth, now, 300);   // a pause: no packets, still inside the silence timeout
  assert(mouth.shape().visible);
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

// The speaker grille: the second mouth style, asked for on 2026-09-17. The
// question it has to answer is not "can it show loudness" -- any bar can -- but
// whether it can still carry feeling once the lips are gone.
// Keep speaking, as the app does: a packet every 50 ms. Without this the mouth
// correctly goes away after kSilenceRestMs, which is the model working, not a
// grille that failed to appear.
static void speak(MouthModel& mouth, uint32_t& now, uint8_t open, int8_t shape, uint32_t ms) {
  static uint32_t sequence = 100;
  for (uint32_t elapsed = 0; elapsed < ms; elapsed += 50) {
    mouth.receive(++sequence, open, shape, now);
    runFor(mouth, now, 50);
  }
}

void grilleShowsSpeechAndMood() {
  stanbot::MouthModel mouth;
  uint32_t now = 1000;
  // Silent: nothing at all, the same as the capsule. A grille that sits there
  // all day would be a feature of the face, not something Stanbot does.
  mouth.update(now);
  assert(!mouth.grille().visible);

  // Speaking quietly: the panel is there, no sound coming out of it yet.
  speak(mouth, now, 10, 0, 400);
  const stanbot::GrilleShape quiet = mouth.grille();
  assert(quiet.visible);
  assert(quiet.slotCount == stanbot::MouthModel::kGrilleSlots);
  assert(quiet.arcCount == 0);

  // Louder: arcs appear and reach further, and the slots open apart.
  speak(mouth, now, 100, 0, 500);
  const stanbot::GrilleShape loud = mouth.grille();
  assert(loud.arcCount == stanbot::MouthModel::kMaxArcs);
  assert(loud.arcLength > quiet.arcLength);
  assert(loud.slotSpacing > quiet.slotSpacing);
  // The body does NOT breathe in and out: a panel that changes size reads as a
  // mouth again, which is the thing this style exists not to be.
  assert(loud.height == quiet.height);
  std::printf("  grille: %d arcs at full voice, reach %d, slots %d apart\n",
              loud.arcCount, loud.arcLength, loud.slotSpacing);

  // Mood is the whole argument for this style being usable. A speaker cannot
  // frown, so the slots lean: sad sags, pleased lifts, and neutral is flat.
  mouth.setMood(0.0f);
  assert(mouth.grille().tilt == 0);
  mouth.setMood(-1.0f);
  const int sad = mouth.grille().tilt;
  mouth.setMood(1.0f);
  const int pleased = mouth.grille().tilt;
  assert(sad > 0 && pleased < 0 && sad == -pleased);
  std::printf("  grille: mood bends the slots %d px, sad against pleased\n", sad);

  // Brightness stretches the arcs: an "ee" reaches further than an "oo" at the
  // same loudness, which is the timbre the capsule showed by going wide.
  mouth.setMood(0.0f);
  speak(mouth, now, 100, 100, 500);
  const int bright = mouth.grille().arcLength;
  speak(mouth, now, 100, -100, 500);
  assert(bright >= mouth.grille().arcLength);

  // And it leaves the way the capsule does, growing away from the centre,
  // rather than switching off.
  for (int i = 0; i < 200 && mouth.grille().visible; ++i) { now += 16; mouth.update(now); }
  assert(!mouth.grille().visible);
}

int main() {
  parsesOnlyWellFormedPackets();
  hiddenUntilSpeechThenGrowsIn();
  staysThroughShortPauses();
  opensWithLoudnessAndShapesWithTheVoice();
  returnsToTheLineWhenPacketsStop();
  staleAndRepeatedSequencesAreIgnored();
  stalledLoopDoesNotFlingTheSprings();
  grilleShowsSpeechAndMood();
  std::puts("mouth model: all tests passed");
  return 0;
}
