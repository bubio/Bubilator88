#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>

using namespace metal;

// Thanos-style dissolve effect.
// Adapted from https://gist.github.com/Codelaby/00dc0387cca537ac2854f22532166fb9
// (base concept: https://x.com/du_yuan161/status/2047713364810555890)

static float thanos_hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

[[ stitchable ]] half4 thanosDissolve(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float progress
) {
    if (progress <= 0.0) {
        return layer.sample(position);
    }
    if (progress >= 1.0) {
        return half4(0.0);
    }

    float2 blockID = floor(position);
    float r1 = thanos_hash21(blockID);
    float r2 = thanos_hash21(blockID + float2(127.1, 311.7));
    float r3 = thanos_hash21(blockID + float2(269.5, 183.3));
    float r4 = thanos_hash21(blockID + float2(419.2,  53.7));

    float2 normalizedPos = position / size;
    float sweepPos = (normalizedPos.x + (1.0 - normalizedPos.y)) * 0.5;
    float startThreshold = sweepPos * 0.4 + r1 * 0.15;

    float localProgress = clamp(
        (progress - startThreshold) / (1.0 - startThreshold),
        0.0,
        1.0
    );
    float eased = smoothstep(0.0, 1.0, localProgress);

    float baseAngle = -0.785398; // -45° (toward upper-right)
    float angleVariation = (r2 - 0.5) * 1.92;
    float angle = baseAngle + angleVariation;
    float2 dir = float2(cos(angle), sin(angle));

    float speed = 0.3 + r3 * 1.4;
    float mag = eased * 200.0 * speed;

    float wobble = sin(localProgress * 6.28 + r4 * 6.28) * (8.0 + r4 * 12.0) * eased;
    float2 perpDir = float2(-dir.y, dir.x);
    float2 displacement = dir * mag + perpDir * wobble;

    float2 samplePos = position - displacement;
    if (samplePos.x < 0.0 || samplePos.x > size.x ||
        samplePos.y < 0.0 || samplePos.y > size.y) {
        return half4(0.0);
    }

    half4 color = layer.sample(samplePos);
    float alphaFade = 1.0 - smoothstep(0.05, 0.7, localProgress);
    color *= half(alphaFade);

    half r = layer.sample(samplePos + float2(2, 0)).r;
    half g = layer.sample(samplePos).g;
    half b = layer.sample(samplePos - float2(2, 0)).b;
    float edge = smoothstep(0.0, 0.15, localProgress)
               - smoothstep(0.15, 0.30, localProgress);
    color.rgb += half3(r, g, b) * edge;

    return color;
}
