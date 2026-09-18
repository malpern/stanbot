// The robot's closed eyes must be the Mac's closed eyes.
//
// Falling asleep used to collapse each eye to a 2 px bar, which read as the
// picture failing rather than as eyes closing, while the Mac drew a soft
// sagging curve. These check the geometry the robot actually asks the display
// for, because the only other way to know is to watch the robot's screen and
// judge by eye -- and "looks about right" is how the two drifted apart.
//
//   c++ -std=c++17 -include initializer_list -I companion/stubs \
//       companion/test_closed_eye.cpp

#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

// companion/stubs/Arduino.h supplies the clock, constrain and the colour names.
#include <cstdint>
uint32_t stanbot_test_now_ms = 0;

/// Stands in for the M5GFX display: it draws nothing and remembers everything.
struct Recorder {
    struct Arc { int x, y, r0, r1, a0, a1; };
    struct Rect { int x, y, w, h, r; };
    struct Circle { int x, y, r; };
    std::vector<Arc> arcs;
    std::vector<Rect> rects;
    std::vector<Circle> circles;

    void fillScreen(uint16_t) { arcs.clear(); rects.clear(); circles.clear(); }
    void fillArc(int x, int y, int r0, int r1, int a0, int a1, uint16_t) {
        arcs.push_back({x, y, r0, r1, a0, a1});
    }
    void fillRoundRect(int x, int y, int w, int h, int r, uint16_t) {
        rects.push_back({x, y, w, h, r});
    }
    void fillCircle(int x, int y, int r, uint16_t) { circles.push_back({x, y, r}); }
    void fillTriangle(int, int, int, int, int, int, uint16_t) {}
    void drawWideLine(int, int, int, int, int, uint16_t) {}
};

#include "../firmware/lib/StanbotEyes/src/StanbotEyes.h"

// The Mac's ClosedEye at the robot's own 320x240 scale (StanbotEyes.swift:
// sleepy pose width 88, frame 0.8 of it, quad control at maxY * 1.6, so the
// midpoint of the curve sits half that below the ends).
static constexpr double kMacWidth = 88 * 0.8;
static constexpr double kMacSag = 0.5 * (22.0 * 1.6);

/// End-to-end width and the drop from the ends to the lowest point, for an arc
/// swept symmetrically about straight down (90 degrees, clockwise from 3
/// o'clock, y increasing downward).
static void arcExtent(const Recorder::Arc& arc, double& width, double& sag) {
    const double radius = (arc.r0 + arc.r1) / 2.0;
    const double sweep = (90 - arc.a0) * M_PI / 180.0;
    width = 2 * radius * std::sin(sweep);
    sag = radius * (1 - std::cos(sweep));
}

/// Run the eyes to a given moment, returning what they drew last.
static Recorder drawAt(StanbotEyes& eyes, uint32_t now) {
    Recorder screen;
    stanbot_test_now_ms = now;
    eyes.update(screen, now);
    return screen;
}

static void test_shut_eyes_match_the_mac_curve() {
    StanbotEyes eyes;
    eyes.begin(0);
    eyes.beginSleep(0);
    // Well past kCloseMs: fully shut.
    Recorder screen = drawAt(eyes, stanbot::SleepCurtain::kCloseMs + 500);

    assert(screen.arcs.size() == 2 && "a shut eye is an arc, not a squashed rectangle");
    for (const auto& arc : screen.arcs) {
        double width = 0, sag = 0;
        arcExtent(arc, width, sag);
        // Within a couple of pixels of the Mac's curve: the same character,
        // drawn by a different renderer.
        assert(std::fabs(width - kMacWidth) <= 3.0 && "closed eye is not the Mac's width");
        assert(std::fabs(sag - kMacSag) <= 3.0 && "closed eye does not sag like the Mac's");
        assert(arc.r1 - arc.r0 == 9 && "stroke weight should match the Mac's lineWidth");
        // It sags: the ring's centre sits above the eye, so the ends turn up.
        assert(arc.y < 120 && "the arc's centre must be above the eye line");
    }
    assert(screen.circles.size() == 4 && "each arc needs two round caps, as the Mac's stroke has");
}

static void test_open_eyes_are_unchanged() {
    StanbotEyes eyes;
    eyes.begin(0);
    Recorder screen = drawAt(eyes, 100);
    assert(screen.arcs.empty() && "an open eye must not be drawn as a curve");
    assert(screen.rects.size() >= 2 && "open eyes are still rounded rectangles");
}

static void test_the_curve_grows_in_rather_than_popping() {
    // Through a real close, the sag only ever deepens. A jump straight to the
    // full curve is what "popping" looks like on the screen.
    StanbotEyes eyes;
    eyes.begin(0);
    eyes.beginSleep(0);
    double previous = -1;
    bool sawCurve = false;
    for (uint32_t now = 40; now <= stanbot::SleepCurtain::kCloseMs + 200; now += 40) {
        Recorder screen = drawAt(eyes, now);
        if (screen.arcs.empty()) continue;   // still an open or flattening eye
        sawCurve = true;
        double width = 0, sag = 0;
        arcExtent(screen.arcs.front(), width, sag);
        assert(sag >= previous - 0.5 && "the sag must deepen as the eye shuts, never jump back");
        previous = sag;
    }
    assert(sawCurve && "the eye never became a curve while closing");
    assert(previous > 10 && "fully shut should be a real curve");
}

static void test_waking_opens_the_eyes_again() {
    StanbotEyes eyes;
    eyes.begin(0);
    eyes.beginSleep(0);
    drawAt(eyes, stanbot::SleepCurtain::kCloseMs + 100);
    eyes.endSleep(stanbot::SleepCurtain::kCloseMs + 100);
    Recorder screen = drawAt(eyes, stanbot::SleepCurtain::kCloseMs + 100
                                   + stanbot::SleepCurtain::kOpenMs + 100);
    assert(screen.arcs.empty() && "a woken eye must be an eye again, not a closed lid");
}

static void test_the_trouble_face_also_closes_its_eyes() {
    // Being in trouble does not stop Stanbot sleeping. Until 2026-09-18
    // drawTrouble ignored the sleep curtain entirely, so a robot that slept
    // while faulted held its X's wide open until the screen went black.
    StanbotEyes eyes;
    eyes.begin(0);
    eyes.setEmotion(StanbotEmotion::Trouble);
    eyes.beginSleep(0);
    Recorder screen = drawAt(eyes, stanbot::SleepCurtain::kCloseMs + 500);

    assert(screen.arcs.size() >= 2 && "the shut trouble face should draw closed lids");
    // Two closed eyes and the frown: the frown is the one low on the screen.
    int lids = 0, frowns = 0;
    for (const auto& arc : screen.arcs) {
        if (arc.y > 150) ++frowns; else ++lids;
    }
    assert(lids == 2 && "both eyes should be closed lids");
    assert(frowns == 1 && "the frown should still be there: it is still in trouble");
}

static void test_the_frown_stays_on_the_screen() {
    StanbotEyes eyes;
    eyes.begin(0);
    eyes.setEmotion(StanbotEmotion::Trouble);
    Recorder screen = drawAt(eyes, 100);
    for (const auto& arc : screen.arcs) {
        if (arc.y <= 150) continue;                  // that is an eye, not the frown
        assert(arc.y - arc.r1 >= 0 && "the frown runs off the top");
        // The visible part is the TOP of the ring, so the lowest ink is a
        // little above the centre -- but the centre plus the radius must still
        // leave room, or the curve crowds the bottom edge as it used to.
        assert(arc.y + 10 <= 240 && "the frown crowds the bottom of the screen");
    }
}

int main() {
    test_shut_eyes_match_the_mac_curve();
    test_open_eyes_are_unchanged();
    test_the_curve_grows_in_rather_than_popping();
    test_waking_opens_the_eyes_again();
    test_the_trouble_face_also_closes_its_eyes();
    test_the_frown_stays_on_the_screen();
    std::printf("closed eye: all checks passed\n");
    return 0;
}
