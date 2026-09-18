// Looking out through Stanbot's eyes, as a SwiftUI layerEffect over the camera
// picture while it wakes or falls asleep (EyeAperture.swift). SwiftUI's own
// blur and mask gave the choreography; this adds the two things only a shader
// can:
//
//  - Light through the lids. Closed eyelids are not black: a lit room glows
//    warm through them. Outside the eye openings the frame shows a dim, warm,
//    heavily diffused version of the scene, strongest near the openings.
//  - Bokeh instead of a Gaussian. Unfocused eyes bloom bright things (a window,
//    a lamp) into soft discs rather than smearing everything equally: a disc of
//    samples weighted toward the bright ones.
//
// Compiled with the other shaders into StanbotShaders.metallib by build-app.sh.
// Without the library (swift test, swift run) EyeApertureVeil falls back to
// SwiftUI's blur and mask.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float roundedBoxDistance(float2 p, float2 halfSize, float radius) {
    float r = min(radius, min(halfSize.x, halfSize.y));
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// eye: centre.xy, half size.zw, in points; a closed eye has zero half height.
static float eyeDistance(float2 position, float4 eye, float radius) {
    if (eye.z <= 0.25 || eye.w <= 0.25) return 1e5;
    return roundedBoxDistance(position - eye.xy, eye.zw, radius);
}

// focus: 0 soft ... 1 sharp. lidLight: 0 none ... 1 full glow through the lids.
// softness: the lid edge, in points.
[[ stitchable ]]
half4 stanbotEyeView(float2 position, SwiftUI::Layer layer, float2 size, float4 leftEye, float4 rightEye,
                     float radius, float focus, float lidLight, float softness) {
    const float3 luma = float3(0.2126, 0.7152, 0.0722);
    float d = min(eyeDistance(position, leftEye, radius), eyeDistance(position, rightEye, radius));
    float inside = 1.0 - smoothstep(-softness, softness, d);

    // Wide open and sharp: the picture, untouched -- alpha included, which is
    // why a fully open eye never showed the black frame described below.
    float soft = 1.0 - clamp(focus, 0.0, 1.0);
    if (inside >= 0.999 && soft <= 0.001) return layer.sample(position);

    // What the eye sees: a disc of samples on a golden-angle spiral, the bright
    // ones weighted up so highlights bloom rather than smear.
    float3 view = float3(layer.sample(position).rgb);
    float blurRadius = 26.0 * soft * soft * (size.y / 720.0 + 0.4);
    if (blurRadius > 0.75 && inside > 0.001) {
        float3 sum = float3(0.0);
        float weight = 0.0;
        const int taps = 28;
        for (int i = 0; i < taps; ++i) {
            float t = (float(i) + 0.5) / float(taps);
            float angle = 2.39996323 * float(i);
            float2 offset = blurRadius * sqrt(t) * float2(cos(angle), sin(angle));
            float3 c = float3(layer.sample(position + offset).rgb);
            float l = dot(c, luma);
            float w = 1.0 + 7.0 * l * l * l * l;   // bright samples dominate: bokeh
            sum += c * w;
            weight += w;
        }
        view = sum / weight;
    }
    // Morning: washed out and a little bright until focus arrives.
    float grey = dot(view, luma);
    view = mix(view, float3(grey), 0.5 * soft);
    view *= 1.0 + 0.10 * soft;

    // Through the lids: the room's light, diffused by skin. A few very wide
    // samples for how bright it is out there, tinted warm, brightest near the
    // openings where the lids are thinnest.
    float3 lid = float3(0.0);
    if (lidLight > 0.001 && inside < 0.999) {
        // Skin diffuses light a long way, so the taps are wide, in three rings,
        // and the whole pattern is turned by a per-pixel hash: what would be
        // ghost copies of the scene's edges becomes a fine, still grain.
        float room = 0.0;
        const int wide = 18;
        float reach = min(150.0, 0.26 * size.y);
        float turn = 6.2831853 * fract(sin(dot(floor(position), float2(12.9898, 78.233))) * 43758.5453);
        for (int i = 0; i < wide; ++i) {
            float ring = (float(i % 3) + 1.0) / 3.0;
            float angle = turn + 2.39996323 * float(i);
            room += dot(float3(layer.sample(position + reach * ring * float2(cos(angle), sin(angle))).rgb), luma);
        }
        room /= float(wide);
        float near = exp(-max(d, 0.0) / (0.30 * size.y));
        float3 warm = float3(0.80, 0.27, 0.13);
        lid = warm * (0.05 + 0.42 * room) * lidLight * (0.30 + 0.70 * near);
    }

    float3 rgb = mix(lid, view, inside);
    // Keep the picture's own alpha instead of forcing every pixel opaque.
    //
    // `layerEffect(maxSampleOffset:)` GROWS the layer so the wide taps above
    // have somewhere to read from -- 160 points on every side here -- and this
    // shader runs across all of it. Returning alpha 1 unconditionally therefore
    // painted an opaque black frame far outside the picture, which landed on
    // top of the face behind it: during the opening sequence a black box
    // appeared over the eyes and vanished a second later, as the lids opened
    // and the picture took over. Reported 2026-09-18.
    //
    // Outside the picture the layer samples transparent, so alpha is 0 there
    // and nothing is drawn; inside it the picture is opaque and the lid glow
    // reads exactly as before. Premultiplied, as SwiftUI layers are.
    float alpha = float(layer.sample(position).a);
    return half4(half3(rgb * alpha), half(alpha));
}
