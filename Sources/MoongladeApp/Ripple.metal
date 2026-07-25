#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Water-drop ripple for the expand transition: a damped sine wave travels
/// outward from `origin`, displacing each sample radially (the refraction)
/// and brightening the crests (the glints). Only the SwiftUI-rendered layer
/// — scrim and content — runs through this; the live glass backdrop is
/// composited by the window server and cannot be sampled here.
[[ stitchable ]] half4 expansionRipple(
    float2 position,
    SwiftUI::Layer layer,
    float2 origin,
    float time,
    float amplitude,
    float frequency,
    float decay,
    float speed
) {
    float dist = length(position - origin);
    float delay = dist / speed;
    float t = max(0.0, time - delay);
    float rippleAmount = amplitude * sin(frequency * t) * exp(-decay * t);
    float2 direction = dist > 0.001 ? (position - origin) / dist : float2(0.0, 0.0);
    half4 color = layer.sample(position + rippleAmount * direction);
    // Crest highlight: proportional to the local displacement, scaled by
    // alpha so the transparent surround never glows. The scrim this runs on
    // is a dark low-alpha wash, so the glint leans bright to read through.
    color.rgb += 0.4 * (rippleAmount / amplitude) * color.a;
    return color;
}
