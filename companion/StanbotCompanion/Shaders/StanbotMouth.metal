// Stanbot's speaking mouth, as a SwiftUI colorEffect over a plain rectangle.
// The same shape the robot draws (MouthModel.h): a grey capsule a little dimmer
// than the irises with a dark opening, here with what a small glowing screen
// adds: soft antialiased edges, a light that bleeds past the rim, a faint lip
// highlight, and a dim inner light that rises with the voice. Calm on purpose:
// nothing flashes, and at rest there is no mouth at all.
//
// Compiled with the other shaders into StanbotShaders.metallib by build-app.sh.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Signed distance to a capsule (a box with fully rounded ends) centred at 0.
static float capsuleDistance(float2 p, float2 halfSize) {
    float r = min(halfSize.x, halfSize.y);
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// position: this pixel, in points. size: the rectangle, in points.
// unit: points per robot display pixel. mouth: width, height in robot pixels.
// rim: robot pixels of grey around the opening. level: loudness 0...1.
// presence: 0...1 as the mouth grows in and fades. time: seconds.
[[ stitchable ]]
half4 stanbotMouth(float2 position, half4 color, float2 size, float unit, float2 mouth,
                   float rim, float level, float presence, float time) {
    if (presence <= 0.0 || mouth.x < 0.5) return half4(0.0h);
    float2 p = position - size * 0.5;
    float aa = 0.75;                                   // one screen pixel of softness
    float2 outerHalf = max(mouth * unit * 0.5, float2(0.5));
    float dOuter = capsuleDistance(p, outerHalf);

    float2 innerHalf = outerHalf - rim * unit;
    bool hasInner = innerHalf.y > unit && innerHalf.x > unit;
    float dInner = hasInner ? capsuleDistance(p, innerHalf) : 1e6;

    float lit = 1.0 - smoothstep(-aa, aa, dOuter);      // inside the capsule
    float hole = hasInner ? 1.0 - smoothstep(-aa, aa, dInner) : 0.0;

    // The rim: grey a little dimmer than the eyes (0.74), lighter toward the top
    // lip, with the faintest slow sheen travelling along it while speaking.
    float vertical = clamp(p.y / max(outerHalf.y, 1.0), -1.0, 1.0);
    float grey = 0.60 + 0.05 * (-vertical);
    grey += 0.025 * level * sin(time * 2.2 + p.x / max(unit, 0.001) * 0.12);
    // A thin highlight just inside the top edge of the opening.
    float lip = hasInner ? exp(-pow((p.y + innerHalf.y + 0.6 * unit) / (1.1 * unit), 2.0))
                           * (1.0 - smoothstep(0.0, innerHalf.x, abs(p.x))) * 0.10 : 0.0;
    float3 rimColor = float3(grey + lip);

    // The opening: near black, with a dim cool light low inside it that rises
    // with the voice, as if the screen behind it glowed.
    float depth = hasInner ? clamp((p.y + innerHalf.y) / max(2.0 * innerHalf.y, 1.0), 0.0, 1.0) : 0.0;
    float3 innerColor = float3(0.015) + float3(0.10, 0.13, 0.15) * level * depth * depth;

    float3 rgb = mix(rimColor, innerColor, hole);
    float alpha = lit;

    // Light bleeding past the edge, like the eyes' glow; brighter while open.
    // It fades to nothing well inside the drawing rectangle, so no edge shows.
    float2 edge = size * 0.5 - abs(p);
    float room = smoothstep(0.0, 8.0 * unit, min(edge.x, edge.y));
    float glow = exp(-max(dOuter, 0.0) / (3.5 * unit)) * (1.0 - lit) * (0.22 + 0.10 * level) * room;
    float3 premultiplied = rgb * alpha + float3(0.60) * glow;
    alpha = alpha + glow * (1.0 - alpha);

    return half4(half3(premultiplied * presence), half(alpha * presence));
}
