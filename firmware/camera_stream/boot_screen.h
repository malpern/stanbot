#pragma once
#include <M5GFX.h>
#include "splash_model.h"
#include "text_bitmaps.h"
#include "font_montserrat12.h"

// Boot and network-join screen, shown before the eyes take over.
//
// Deliberately borrows the visual language of the KeyPath HID fixture's own
// boot screen so the two devices read as siblings on a bench: a deep teal
// ground, concentric halos, a slow orbit, a progress arc, and a small
// letter-spaced eyebrow over a single large state word.
//
// It draws into the same sprite the eyes use, so it costs no extra framebuffer.
namespace stanbot {

enum class BootPhase { Waking, Joining, Connected, LocalOnly, Failed };

// Draws 8-bit coverage over the background, which is both how the real
// letterforms keep their anti-aliasing and how every fade on these screens is
// done: opacity scales the coverage rather than swapping colours.
inline void blitText(M5Canvas& canvas, const TextBitmap& text, int centreX, int topY,
                     uint32_t colour, uint32_t ground, uint8_t opacity) {
    if (!opacity) return;
    const int left = centreX - text.width / 2;
    const uint32_t fr = colour >> 16 & 0xff, fg = colour >> 8 & 0xff, fb = colour & 0xff;
    const uint32_t br = ground >> 16 & 0xff, bg = ground >> 8 & 0xff, bb = ground & 0xff;
    for (int row = 0; row < text.height; ++row) {
        const int y = topY + row;
        if (y < 0 || y >= canvas.height()) continue;
        for (int col = 0; col < text.width; ++col) {
            const uint32_t coverage = text.coverage[row * text.width + col] * opacity / 255u;
            if (!coverage) continue;
            const int x = left + col;
            if (x < 0 || x >= canvas.width()) continue;
            canvas.drawPixel(x, y, canvas.color565(
                (fr * coverage + br * (255 - coverage)) / 255,
                (fg * coverage + bg * (255 - coverage)) / 255,
                (fb * coverage + bb * (255 - coverage)) / 255));
        }
    }
}

// The Hacker Dojo opening, reconstructed for M5GFX from the KeyPath fixture's
// LVGL original: same palette, same geometry, same timing model. The fixture
// animates real alpha; M5GFX draws opaque, so every fade here is the colour
// blended toward the background by the model's opacity, which looks identical
// on a panel that never shows anything behind it.
class DojoSplash {
public:
    // Logo geometry, in the 92x92 box the fixture uses, so the proportions of
    // hackerdojo.org's mark survive being rescaled to this display.
    struct Bar { int x, y, w, h; };
    static constexpr Bar kBars[4] = {{20, 29, 52, 5}, {16, 40, 60, 5},
                                     {31, 26, 5, 41}, {56, 26, 5, 41}};

    bool render(M5Canvas& canvas, uint32_t elapsedMs) {
        const SplashOutput out = splashStep(elapsedMs);
        const uint16_t ground = canvas.color565(0x08, 0x0c, 0x10);
        canvas.fillSprite(ground);
        if (out.complete) return true;

        // The original's absolute pixel geometry, used unchanged. Its panel is
        // 240x280 and this one is 320x240, but the artwork spans about 180px
        // vertically and 132 horizontally, so it fits here with room to spare
        // and rescaling would only make it differ for no reason.
        const int cx = canvas.width() / 2;
        const int cy = canvas.height() / 2 - 27;

        // `logo_scale` is computed by the shared model but the original's
        // renderer never applies it, so nothing here grows either. Only opacity
        // animates. Getting this wrong is what made the first attempt breathe.
        const int glowPulse = static_cast<int>(sinf(elapsedMs / 230.0f) * 4.0f);
        const uint8_t glowAlpha = static_cast<uint8_t>(
            out.foregroundOpacity * static_cast<uint32_t>(22 + glowPulse) / 255u);
        canvas.fillCircle(cx, cy, 66, blend(canvas, kRed, kGround, glowAlpha));

        // A 2px border on a 118px circle, fading out over 800ms and restarting.
        const uint32_t ringPhase = elapsedMs % 800u;
        const uint16_t ringFade = static_cast<uint16_t>(255u - ringPhase * 255u / 800u);
        const uint8_t ringAlpha = static_cast<uint8_t>(
            out.foregroundOpacity * ringFade * 44u / (255u * 255u));
        const uint16_t ringColor = blend(canvas, kRed, kGround, ringAlpha);
        canvas.drawCircle(cx, cy, 59, ringColor);
        canvas.drawCircle(cx, cy, 58, ringColor);

        // The mark: a 92px rounded square, radius 24, carrying four white bars
        // at hackerdojo.org's own proportions.
        const uint16_t logoColor = blend(canvas, kRed, kGround, out.foregroundOpacity);
        const uint32_t logoRgb = mix(kRed, kGround, out.foregroundOpacity);
        const uint16_t barColor = blend(canvas, kWhite, logoRgb, out.foregroundOpacity);
        const int left = cx - 46, top = cy - 46;
        canvas.fillRoundRect(left, top, 92, 92, 24, logoColor);
        for (const Bar& bar : kBars)
            canvas.fillRect(left + bar.x, top + bar.y, bar.w, bar.h, barColor);

        // Wordmark and location trail the logo in and rise as they arrive.
        // These are real Montserrat, pre-rendered from the same face LVGL uses,
        // so the letterforms match the fixture rather than merely resembling it.
        const int rise = 5 - static_cast<int>(out.wordmarkOpacity * 5u / 255u);
        blitText(canvas, kHackerDojo, cx, cy + 48 + rise, kWhite, kGround, out.wordmarkOpacity);
        blitText(canvas, kLocation, cx, cy + 74 + rise, kLocationColour, kGround,
                 static_cast<uint8_t>(out.wordmarkOpacity * 3u / 4u));
        blitText(canvas, kEyebrow, cx, canvas.height() - 18, kVersion, kGround,
                 static_cast<uint8_t>(out.wordmarkOpacity * 2u / 3u));
        canvas.setTextDatum(textdatum_t::top_left);
        return false;
    }

private:
    // The original's palette, verbatim.
    static constexpr uint32_t kRed = 0xe13838;
    static constexpr uint32_t kWhite = 0xffffff;
    static constexpr uint32_t kGround = 0x080c10;
    static constexpr uint32_t kLocationColour = 0x9aa7ad;
    static constexpr uint32_t kVersion = 0x627078;

    // Mixing happens in 24-bit and converts to the panel's 565 exactly once.
    // Round-tripping through 565 first, as the first attempt did, quantised the
    // low alphas the glow and ring live at and flattened both animations.
    //
    // Note the conversion is color565, not color888: this sprite is 16 bits per
    // pixel, and color888 returns a 24-bit value that the sprite silently
    // truncates. 0xe13838 becomes 0x3838, which reads back as blue, which is
    // exactly how the Hacker Dojo mark came out blue on the first build.
    static uint32_t mix(uint32_t colour, uint32_t ground, uint8_t alpha) {
        const uint32_t r = ((colour >> 16 & 0xff) * alpha + (ground >> 16 & 0xff) * (255 - alpha)) / 255;
        const uint32_t g = ((colour >> 8 & 0xff) * alpha + (ground >> 8 & 0xff) * (255 - alpha)) / 255;
        const uint32_t b = ((colour & 0xff) * alpha + (ground & 0xff) * (255 - alpha)) / 255;
        return (r << 16) | (g << 8) | b;
    }

    // M5GFX draws opaque, so an alpha fade becomes a colour mix with the ground.
    static uint16_t blend(M5Canvas& canvas, uint32_t colour, uint32_t ground, uint8_t alpha) {
        const uint32_t rgb = mix(colour, ground, alpha);
        return canvas.color565(rgb >> 16 & 0xff, rgb >> 8 & 0xff, rgb & 0xff);
    }

};

// A quiet badge on the face: signal bars with a slash, shown only while the
// robot has no network. Nothing is drawn when it is connected, so the face is
// unmarked in the normal case and the badge means exactly one thing.
//
// Deliberately bars and a slash rather than the usual arcs: at this size arcs
// depend on the renderer's angle convention and read as a smudge, while bars
// stay legible and unambiguous.
inline void drawNoNetworkBadge(M5Canvas& canvas) {
    constexpr int kBarWidth = 3, kGap = 2, kBars = 4;
    const int right = canvas.width() - 8;
    const int bottom = 22;
    const uint16_t dim = canvas.color565(0x8c, 0x3a, 0x36);
    const int left = right - (kBars * kBarWidth + (kBars - 1) * kGap);
    for (int bar = 0; bar < kBars; ++bar) {
        const int height = 4 + bar * 3;
        canvas.fillRect(left + bar * (kBarWidth + kGap), bottom - height, kBarWidth, height, dim);
    }
    // The slash, drawn twice for a little weight at this size.
    const uint16_t slash = canvas.color565(0xd8, 0x6b, 0x60);
    canvas.drawLine(left - 2, bottom + 1, right + 1, bottom - 16, slash);
    canvas.drawLine(left - 2, bottom + 2, right + 1, bottom - 15, slash);
}

class BootScreen {
public:
    void begin(uint32_t nowMs) { startedMs_ = nowMs; }

    void setPhase(BootPhase phase, const char* detail, uint32_t nowMs) {
        if (phase == phase_ && strcmp(detail, detail_) == 0) return;
        phase_ = phase;
        snprintf(detail_, sizeof(detail_), "%s", detail);
        phaseAtMs_ = nowMs;
    }

    BootPhase phase() const { return phase_; }
    uint32_t phaseAgeMs(uint32_t nowMs) const { return nowMs - phaseAtMs_; }
    uint32_t ageMs(uint32_t nowMs) const { return nowMs - startedMs_; }

    void render(M5Canvas& canvas, uint32_t nowMs) {
        const int width = canvas.width(), height = canvas.height();
        const int cx = width / 2, cy = height / 2 - 12;
        canvas.fillSprite(canvas.color565(0x07, 0x11, 0x17));

        // Eyebrow, in the same face as everything else.
        blitText(canvas, kEyebrow, 10 + kEyebrow.width / 2, 10, 0x71909d, 0x071117, 255);

        // Halos: two dim discs, the outer one breathing slowly.
        const float breathe = 0.5f + 0.5f * sinf(static_cast<float>(nowMs) / 900.0f);
        canvas.fillCircle(cx, cy, 74 + static_cast<int>(3 * breathe),
                          canvas.color565(0x17, 0x39, 0x46));
        canvas.fillCircle(cx, cy, 60, canvas.color565(0x15, 0x35, 0x41));

        // Orbit: a short arc sweeping continuously while anything is pending.
        if (phase_ == BootPhase::Waking || phase_ == BootPhase::Joining) {
            const int start = static_cast<int>((nowMs / 4) % 360);
            canvas.fillArc(cx, cy, 64, 67, start, start + 70,
                           canvas.color565(0x2f, 0x69, 0x70));
        }

        // Progress: fills as the join proceeds; complete and green once up.
        const uint16_t accent = phase_ == BootPhase::Connected
            ? canvas.color565(0x56, 0xdd, 0xb3)
            : phase_ == BootPhase::Failed ? canvas.color565(0xe1, 0x38, 0x38)
                                          : canvas.color565(0x2f, 0x69, 0x70);
        canvas.fillArc(cx, cy, 54, 57, 0, 360, canvas.color565(0x18, 0x34, 0x3e));
        int sweep = 360;
        if (phase_ == BootPhase::Waking) sweep = 40;
        else if (phase_ == BootPhase::Joining)
            sweep = 60 + static_cast<int>(240.0f * (1.0f - expf(-phaseAgeMs(nowMs) / 6000.0f)));
        if (sweep > 0) canvas.fillArc(cx, cy, 54, 57, -90, -90 + sweep, accent);

        // Core, with a hint of the eyes that are about to take over.
        canvas.fillCircle(cx, cy, 40, canvas.color565(0x0d, 0x20, 0x28));
        canvas.drawCircle(cx, cy, 40, canvas.color565(0x2f, 0x69, 0x70));
        const bool blink = (nowMs / 120) % 24 == 0;
        const int eyeHeight = blink ? 2 : 16;
        canvas.fillRoundRect(cx - 19, cy - eyeHeight / 2, 13, eyeHeight, 5, accent);
        canvas.fillRoundRect(cx + 6, cy - eyeHeight / 2, 13, eyeHeight, 5, accent);

        // State word in the same pre-rendered Montserrat as the splash, so the
        // two screens are one typeface; the detail line is dynamic (an SSID or
        // an address) and uses the loaded 12px face.
        const uint32_t ground = 0x071117;
        if (const TextBitmap* word = title()) blitText(canvas, *word, cx, cy + 52, 0xe6f0f4, ground, 255);
        canvas.setTextDatum(textdatum_t::top_center);
        canvas.setTextColor(canvas.color565(0x62, 0x70, 0x78));
        canvas.drawString(detail_, cx, cy + 84);
        canvas.setTextDatum(textdatum_t::top_left);
    }

private:
    const TextBitmap* title() const {
        switch (phase_) {
            case BootPhase::Waking:    return &kWakingUp;
            case BootPhase::Joining:   return &kJoining;
            case BootPhase::Connected: return &kConnected;
            case BootPhase::LocalOnly: return &kUsbOnly;
            case BootPhase::Failed:    return &kNoNetwork;
        }
        return nullptr;
    }

    BootPhase phase_ = BootPhase::Waking;
    char detail_[48] = "starting up";
    uint32_t startedMs_ = 0;
    uint32_t phaseAtMs_ = 0;
};

}  // namespace stanbot
