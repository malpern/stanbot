// Checks the ported Hacker Dojo splash model against the contract of the
// KeyPath fixture original it was copied from.
//   c++ -std=c++17 -O1 -fsanitize=address,undefined -Wall -Wextra \
//       companion/test_splash_model.cpp -o /tmp/ts && /tmp/ts
#include "../firmware/camera_stream/splash_model.h"
#include <cassert>
#include <cstdio>

int main() {
    using namespace stanbot;
    // Starts invisible, ends invisible and complete.
    assert(splashStep(0).foregroundOpacity == 0);
    assert(!splashStep(0).complete);
    assert(splashStep(kSplashTotalMs).complete);
    assert(splashStep(kSplashTotalMs).foregroundOpacity == 0);
    assert(splashStep(kSplashTotalMs + 5000).complete);

    // Fade in is monotonic and reaches full by the end of the fade.
    uint8_t previous = 0;
    for (uint32_t t = 0; t <= kSplashFadeInMs; ++t) {
        const uint8_t now = splashStep(t).foregroundOpacity;
        assert(now >= previous);
        previous = now;
    }
    assert(splashStep(kSplashFadeInMs).foregroundOpacity == 255);

    // Fully visible through the hold, so the logo is readable, not a flicker.
    for (uint32_t t = kSplashFadeInMs; t < kSplashHoldEndMs; ++t)
        assert(splashStep(t).foregroundOpacity == 255);
    assert(kSplashHoldEndMs - kSplashFadeInMs >= 900);

    // Fade out is monotonic down to nothing.
    previous = 255;
    for (uint32_t t = kSplashHoldEndMs; t <= kSplashTotalMs; ++t) {
        const uint8_t now = splashStep(t).foregroundOpacity;
        assert(now <= previous);
        previous = now;
    }

    // The wordmark trails the logo in, which is the whole point of the offset.
    assert(splashStep(120).wordmarkOpacity == 0);
    assert(splashStep(60).wordmarkOpacity < splashStep(60).foregroundOpacity);
    assert(splashStep(420).wordmarkOpacity == 255);

    // The logo grows slightly throughout and never shrinks.
    uint16_t scale = 0;
    for (uint32_t t = 0; t <= kSplashTotalMs; ++t) {
        const uint16_t now = splashStep(t).logoScale;
        assert(now >= scale);
        scale = now;
    }
    assert(splashStep(kSplashTotalMs).logoScale == 274);

    printf("splash model: checks passed\n");
    return 0;
}
