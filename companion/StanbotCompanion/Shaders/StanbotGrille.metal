// Stanbot's mouth as a speaker grille, for the Mac.
//
// The robot draws this as flat fills with hard edges, because an ESP32-S3 is
// painting into a 16-bit sprite with no alpha while it also runs the camera and
// the servos. None of that is true here, and the owner's direction (2026-09-17)
// is not to pretend it is: this is the same grille with everything a GPU can
// give it -- a panel with depth, slots lit from within that bloom as the voice
// rises, and arcs that fall off into the dark the way sound does.
//
// Same meaning, same timing, better drawn. Nothing flashes; nothing moves that
// the robot's version does not also move.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float roundedBox(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// Distance to an arc of radius `radius` and half-angle `spread`, centred at the
// origin and opening along +x. The robot draws these as straight bars because a
// 16-bit sprite and an ESP32 cannot afford anything else; here they are the real
// thing -- concentric curves, the way every speaker icon has drawn sound since
// the first one -- which is the whole point of the Mac face being allowed more
// (docs/app-design.md, "Two faces, deliberately unequal").
static float arcDistance(float2 p, float radius, float spread, float thickness) {
    float angle = atan2(p.y, p.x);
    float clamped = clamp(angle, -spread, spread);
    float2 nearest = float2(cos(clamped), sin(clamped)) * radius;
    return length(p - nearest) - thickness * 0.5;
}

// position/size: points. unit: points per robot pixel. body: the panel in robot
// pixels. slots: count, thickness, spacing (robot pixels). tilt: robot pixels
// the outer slots lean, + down for sad. arcs: count, length, gap.
// level: loudness 0...1. presence: 0...1 growing in. time: seconds.
[[ stitchable ]]
half4 stanbotGrille(float2 position, half4 color, float2 size, float unit,
                    float2 body, float3 slots, float tilt, float3 arcs,
                    float level, float presence, float time) {
    if (presence <= 0.0 || body.x < 0.5) return half4(0.0h);
    float2 p = position - size * 0.5;
    float aa = 0.75;

    float2 halfBody = max(body * unit * 0.5, float2(0.5));
    float radius = min(halfBody.x, halfBody.y) * 0.45;
    float dBody = roundedBox(p, halfBody, radius);
    float inBody = 1.0 - smoothstep(-aa, aa, dBody);

    // The panel: dark, and slightly darker toward the bottom, so it reads as a
    // recess in the face rather than a sticker on it.
    float depth = clamp(0.5 + 0.5 * (p.y / max(halfBody.y, 1.0)), 0.0, 1.0);
    float3 panel = mix(float3(0.115), float3(0.055), depth);
    // A hairline of light along the top edge: the lip of a real grille.
    float topEdge = 1.0 - smoothstep(0.0, 1.6, abs(dBody + 0.9));
    panel += 0.10 * topEdge * step(p.y, 0.0);

    // The slots. The middle one stays put and the outer ones lean, so the panel
    // bends with mood rather than sliding.
    int count = int(max(slots.x, 1.0));
    float thickness = max(slots.y * unit, 1.0);
    float spacing = max(slots.z * unit, thickness);
    float slotWidth = max(halfBody.x * 2.0 - 2.0 * 6.0 * unit, unit);
    float slotLight = 0.0;
    float slotBloom = 0.0;
    for (int index = 0; index < count; ++index) {
        float fromCentre = float(index) - float(count - 1) * 0.5;
        float2 centre = float2(0.0, fromCentre * spacing);
        // Mood BOWS each slot rather than moving them apart: the ends drop
        // relative to the middle for sad and lift for pleased, so the three
        // lines read as a frown or a smile. Shifting whole slots up and down --
        // which is what this did first -- just looks like the panel opening,
        // which is loudness, and says nothing about how it feels.
        float across = clamp((p.x) / max(slotWidth * 0.5, 1.0), -1.0, 1.0);
        // Negative, because the shape lands at (centre + offset) and +y is down:
        // a positive tilt must LOWER the ends, which is the frown. Rendered and
        // looked at, because the sign was inverted first time and read as a
        // smile for sad, which is worse than no expression at all.
        float bow = -tilt * unit * across * across;
        float d = roundedBox(p - centre - float2(0.0, bow),
                             float2(slotWidth * 0.5, thickness * 0.5), thickness * 0.5);
        // Clipped to the panel, always. The geometry is fitted so this never
        // has to bite, but a slot drawn outside its own grille breaks the one
        // thing the shape is saying -- that these are cuts in a surface -- and
        // no constant should be able to do that by accident.
        d = max(d, dBody + 1.5);
        slotLight += 1.0 - smoothstep(-aa, aa, d);
        // The light a lit slot spills onto the panel around it.
        slotBloom += exp(-max(d, 0.0) / (2.2 * unit));
    }
    slotLight = clamp(slotLight, 0.0, 1.0);
    slotBloom = clamp(slotBloom, 0.0, 1.0);

    // Slots brighten with the voice rather than changing size: a panel that
    // breathes is a mouth again.
    float3 lit = float3(0.54 + 0.26 * level);
    float3 rgb = panel + slotBloom * 0.16 * (0.4 + 0.6 * level);
    rgb = mix(rgb, lit, slotLight);

    // The arcs: sound leaving the grille. They fall off with distance, and the
    // further one is dimmer, so it reads as the same sound going further rather
    // than two separate marks.
    int arcCount = int(max(arcs.x, 0.0));
    float arcLength = max(arcs.y * unit, 1.0);      // how far the sound carries
    float arcGap = max(arcs.z * unit, 1.0);
    float arcThickness = max(2.5 * unit, 1.0);
    float glow = 0.0;
    float core = 0.0;
    // How wide the fan opens, from the reach: a quiet sound is a small arc close
    // to the panel, a loud one spreads.
    float spread = 0.45 + 0.35 * clamp(level, 0.0, 1.0);
    for (int index = 0; index < arcCount; ++index) {
        float radius = arcGap + arcLength * 0.45 + float(index) * (arcThickness + arcGap);
        float fade = 1.0 - 0.35 * float(index);
        for (int side = -1; side <= 1; side += 2) {
            // Struck from the edge of the panel, so the sound comes OUT of the
            // grille rather than floating beside it.
            float2 q = p - float2(float(side) * halfBody.x, 0.0);
            q.x *= float(side);
            float d = arcDistance(q, radius, spread, arcThickness);
            core += fade * (1.0 - smoothstep(-aa, aa, d));
            glow += fade * exp(-max(d, 0.0) / (3.0 * unit));
        }
    }
    float3 sound = float3(0.70 + 0.25 * level);
    rgb += glow * 0.12 * (0.3 + 0.7 * level);
    rgb = mix(rgb, sound, clamp(core, 0.0, 1.0));

    // Presence fades the whole thing, so it arrives and leaves the way the
    // capsule does -- on the Mac with real opacity, rather than by growing out
    // of the centre because there is none.
    float alpha = clamp(inBody + clamp(core, 0.0, 1.0) + glow * 0.35, 0.0, 1.0) * presence;
    return half4(half3(rgb * alpha), half(alpha));
}
