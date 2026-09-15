#pragma once
#include <stdbool.h>
#include <stdint.h>

// Timing and opacity model for the Hacker Dojo splash.
//
// A faithful port of the KeyPath HID fixture's `fixture_splash_model.c`, so the
// two devices open identically on a bench at the Dojo. The arithmetic is
// deliberately unchanged, integer for integer, rather than re-tuned by eye.
// Rendering is elsewhere; this decides only what is visible when.
namespace stanbot {

constexpr uint32_t kSplashFadeInMs = 260;
constexpr uint32_t kSplashHoldEndMs = 1200;
constexpr uint32_t kSplashTotalMs = 1650;

struct SplashOutput {
    uint8_t foregroundOpacity = 0;
    uint8_t backgroundOpacity = 255;
    uint8_t wordmarkOpacity = 0;
    uint16_t logoScale = 228;   // 256 is unity, matching LVGL's zoom units
    bool complete = false;
};

inline uint16_t smoothstepPerMille(uint32_t elapsed, uint32_t duration) {
    if (elapsed >= duration) return 1000u;
    const uint64_t t = static_cast<uint64_t>(elapsed) * 1000u / duration;
    return static_cast<uint16_t>(t * t * (3000u - 2u * t) / 1000000u);
}

inline SplashOutput splashStep(uint32_t elapsedMs) {
    SplashOutput output;
    const uint16_t reveal = smoothstepPerMille(elapsedMs, kSplashFadeInMs);
    output.foregroundOpacity = static_cast<uint8_t>(255u * reveal / 1000u);
    output.logoScale = static_cast<uint16_t>(228u + 28u * reveal / 1000u);

    const uint32_t wordmarkElapsed = elapsedMs > 120u ? elapsedMs - 120u : 0u;
    const uint16_t wordmarkReveal = smoothstepPerMille(wordmarkElapsed, 300u);
    output.wordmarkOpacity = static_cast<uint8_t>(255u * wordmarkReveal / 1000u);

    if (elapsedMs >= kSplashHoldEndMs) {
        const uint32_t fadeElapsed = elapsedMs - kSplashHoldEndMs;
        const uint16_t fade = smoothstepPerMille(fadeElapsed, kSplashTotalMs - kSplashHoldEndMs);
        const uint16_t remaining = static_cast<uint16_t>(1000u - fade);
        output.foregroundOpacity = static_cast<uint8_t>(255u * remaining / 1000u);
        output.backgroundOpacity = output.foregroundOpacity;
        output.wordmarkOpacity = output.foregroundOpacity;
        output.logoScale = static_cast<uint16_t>(256u + 18u * fade / 1000u);
    }

    if (elapsedMs >= kSplashTotalMs) {
        output.foregroundOpacity = 0u;
        output.backgroundOpacity = 0u;
        output.wordmarkOpacity = 0u;
        output.logoScale = 274u;
        output.complete = true;
    }
    return output;
}

}  // namespace stanbot
