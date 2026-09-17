// Stanbot's screen look, as a SwiftUI colorEffect: a faint pixel grid with a
// hint of red/green/blue subpixel stripes, so the eyes drawn on the Mac read as
// the robot's little LCD rather than flat vector shapes.
//
// Compiled into Stanbot.app/Contents/Resources/StanbotShaders.metallib by
// build-app.sh. Without that file (swift test, swift run) the app draws the
// eyes without it; see StanbotShaders.swift.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]]
half4 stanbotLCD(float2 position, half4 color, float cell, float strength) {
    if (color.a <= 0.0h || cell < 1.0) return color;
    float2 p = fmod(position, cell) / cell;                 // 0...1 within one pixel
    // Darken the gaps between pixels, softly, so it never shimmers.
    float edge = 0.16;
    float gx = smoothstep(0.0, edge, p.x) * smoothstep(1.0, 1.0 - edge, p.x);
    float gy = smoothstep(0.0, edge, p.y) * smoothstep(1.0, 1.0 - edge, p.y);
    half grid = half(mix(1.0 - strength, 1.0, gx * gy));
    // Subpixel stripes: each third of a pixel leans slightly toward R, G or B.
    int third = int(floor(p.x * 3.0));
    half3 tint = third == 0 ? half3(1.08h, 0.96h, 0.96h)
               : third == 1 ? half3(0.96h, 1.08h, 0.96h)
                            : half3(0.96h, 0.96h, 1.08h);
    half3 rgb = color.rgb * grid * mix(half3(1.0h), tint, half(strength));
    return half4(min(rgb, half3(color.a)), color.a);   // stay premultiplied
}
