#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct FilterParams {
    float2 textureDimensions;  // 640x200 (200-line) or 640x400 (400-line/None)
    float2 outputDimensions;   // viewport size in pixels
    uint   scanlineEnabled;    // 1 = on, 0 = off
    uint   is400LineMode;      // 1 = 400-line (no doubling), 0 = 200-line (doubled)
    float  hqOffset;           // diagonal transition offset (default 0.25)
    float  hqGradient;         // gradient scale (default 0.7)
    float  hqMaxBlend;         // max blend cap (default 0.8)
    float  hqPadding;
    float  persistR;           // CRT phosphor persistence: red decay rate
    float  persistG;           // green decay rate
    float  persistB;           // blue decay rate
    float  persistPad;
};

vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                               constant float4 *vertices [[buffer(0)]]) {
    VertexOut out;
    float4 v = vertices[vertexID];
    out.position = float4(v.xy, 0.0, 1.0);
    out.texCoord = v.zw;
    return out;
}

// MARK: - Scanline helper

static float scanlineMultiplier(float2 texCoord, constant FilterParams &params) {
    if (params.scanlineEnabled == 0) return 1.0;
    float srcY = texCoord.y * params.textureDimensions.y;
    if (params.textureDimensions.y > 300) {
        // 400-line texture (doubled or native 400): every 2 rows = 1 scanline
        return step(1.0, fmod(srcY, 2.0)) < 0.5 ? 1.0 : 0.3;
    } else {
        // 200-line texture (content-only): second half of each texel = gap
        return fract(srcY) >= 0.5 ? 0.3 : 1.0;
    }
}

// MARK: - None (Nearest Neighbor)

fragment float4 fragmentNearest(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler s [[sampler(0)]],
                                 constant FilterParams &params [[buffer(0)]]) {
    float4 color = tex.sample(s, in.texCoord);
    float sl = scanlineMultiplier(in.texCoord, params);
    return float4(color.rgb * sl, 1.0);
}

// MARK: - Linear (Bilinear)

fragment float4 fragmentLinear(VertexOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                sampler s [[sampler(0)]],
                                constant FilterParams &params [[buffer(0)]]) {
    float4 color = tex.sample(s, in.texCoord);
    float sl = scanlineMultiplier(in.texCoord, params);
    return float4(color.rgb * sl, 1.0);
}

// MARK: - Bicubic (Catmull-Rom)

static float catmullRomWeight(float x) {
    float ax = abs(x);
    if (ax <= 1.0) {
        return 0.5 * ((2.0 - 5.0 * ax * ax + 3.0 * ax * ax * ax));
    } else if (ax <= 2.0) {
        return 0.5 * (4.0 - 8.0 * ax + 5.0 * ax * ax - ax * ax * ax);
    }
    return 0.0;
}

fragment float4 fragmentBicubic(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler s [[sampler(0)]],
                                 constant FilterParams &params [[buffer(0)]]) {
    float2 texSize = params.textureDimensions;
    float2 texelSize = 1.0 / texSize;
    float2 coord = in.texCoord * texSize - 0.5;
    float2 f = fract(coord);
    float2 base = (floor(coord) + 0.5) * texelSize;

    float4 result = float4(0.0);
    float weightSum = 0.0;
    for (int y = -1; y <= 2; y++) {
        float wy = catmullRomWeight(float(y) - f.y);
        for (int x = -1; x <= 2; x++) {
            float wx = catmullRomWeight(float(x) - f.x);
            float w = wx * wy;
            float2 sampleCoord = base + float2(float(x), float(y)) * texelSize;
            result += tex.sample(s, sampleCoord) * w;
            weightSum += w;
        }
    }
    result /= weightSum;

    float sl = scanlineMultiplier(in.texCoord, params);
    return float4(result.rgb * sl, 1.0);
}

// MARK: - CRT (PC monitor style — subtle curvature, soft scanlines, warm glow)

fragment float4 fragmentCRT(VertexOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             sampler s [[sampler(0)]],
                             constant FilterParams &params [[buffer(0)]]) {
    float2 uv = in.texCoord;

    float4 color = tex.sample(s, uv);

    // Brightness-adaptive scanlines — bright pixels bleed more, dimmer gap
    float srcY = uv.y * params.textureDimensions.y;
    float isGap;
    if (params.textureDimensions.y > 300.0) {
        // 400-line texture (doubled): every 2 rows = 1 scanline
        isGap = step(1.0, fmod(srcY, 2.0));
    } else {
        // 200-line texture (content-only): second half of each texel = gap
        isGap = step(0.5, fract(srcY));
    }
    float brightness = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float gapLevel = mix(0.55, 0.80, brightness);
    float scanline = (isGap > 0.5) ? gapLevel : 1.0;
    color.rgb *= scanline;

    // CRT phosphor glow — slight brightness boost
    color.rgb *= 1.08;

    // Warm color temperature (PC-KD854 style, slight blue reduction)
    color.b *= 0.95;

    // Subtle vignette (PC monitor — very mild corner darkening)
    float2 vig = in.texCoord * 2.0 - 1.0;
    float vignette = 1.0 - smoothstep(1.0, 1.8, length(vig));
    color.rgb *= vignette;

    return float4(clamp(color.rgb, 0.0, 1.0), 1.0);
}

// MARK: - CRT Phosphor Persistence Pass 1 (accumulate to offscreen)
//
// Reads current frame + previous persistence texture. Applies CRT effects
// (scanlines, glow, warmth) then blends with decayed previous frame using
// per-channel decay rates (P22 phosphor: red slowest, blue fastest).

fragment float4 fragmentCRTAccumulate(VertexOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]],
                                       texture2d<float> prevPersist [[texture(1)]],
                                       sampler s [[sampler(0)]],
                                       constant FilterParams &params [[buffer(0)]]) {
    float2 uv = in.texCoord;
    float4 color = tex.sample(s, uv);

    // Brightness-adaptive scanlines
    float srcY = uv.y * params.textureDimensions.y;
    float isGap;
    if (params.textureDimensions.y > 300.0) {
        isGap = step(1.0, fmod(srcY, 2.0));
    } else {
        isGap = step(0.5, fract(srcY));
    }
    float brightness = dot(color.rgb, float3(0.299, 0.587, 0.114));
    float gapLevel = mix(0.55, 0.80, brightness);
    float scanline = (isGap > 0.5) ? gapLevel : 1.0;
    color.rgb *= scanline;

    // Phosphor glow + warm color
    color.rgb *= 1.08;
    color.b *= 0.95;

    // Persistence: decay previous, take max (phosphor afterglow)
    float3 prev = prevPersist.sample(s, in.texCoord).rgb;
    float3 decayed = prev * float3(params.persistR, params.persistG, params.persistB);
    float3 result = max(color.rgb, decayed);

    return float4(clamp(result, 0.0, 1.0), 1.0);
}

// MARK: - CRT Composite Pass 2 (vignette + output to screen)

fragment float4 fragmentCRTComposite(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      sampler s [[sampler(0)]]) {
    float4 color = tex.sample(s, in.texCoord);

    // Subtle vignette (same as fragmentCRT)
    float2 vig = in.texCoord * 2.0 - 1.0;
    float vignette = 1.0 - smoothstep(1.0, 1.8, length(vig));
    color.rgb *= vignette;

    return float4(clamp(color.rgb, 0.0, 1.0), 1.0);
}

// MARK: - High Quality (Scale2x-inspired sub-pixel edge smoothing)
//
// Works in content space (640x200) to handle line doubling correctly.
// Detects diagonal edges via Scale2x rules, then assigns sub-pixel colors
// with smooth blending based on position within the content pixel.
// No blurring — sharp color assignment based on edge geometry.

static bool hqEqual(float3 a, float3 b) {
    float3 d = a - b;
    return dot(d, d) < 0.01;
}

fragment float4 fragmentHighQuality(VertexOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     sampler s [[sampler(0)]],
                                     constant FilterParams &params [[buffer(0)]]) {
    float2 texSize = params.textureDimensions;  // 640x200 or 640x400

    // Texture is already content resolution (200-line mode gets 640x200 directly)
    float contentW = texSize.x;
    float contentH = texSize.y;

    float2 contentCoord = float2(in.texCoord.x * contentW,
                                  in.texCoord.y * contentH);
    float2 contentTexel = floor(contentCoord);
    float2 sp = contentCoord - contentTexel;

    // Texture coordinate for this content pixel's center
    float2 center = float2((contentTexel.x + 0.5) / contentW,
                            (contentTexel.y + 0.5) / contentH);
    float cdx = 1.0 / contentW;
    float cdy = 1.0 / contentH;

    // At x1 (output ≈ content resolution): pure nearest, no processing
    float scale = params.outputDimensions.x / contentW;
    if (scale < 1.5) {
        float3 E = tex.sample(s, center).rgb;
        return float4(E, 1.0);
    }

    // Sample content-space 3x3 neighborhood
    //  A B C
    //  D E F
    //  G H I
    float3 E = tex.sample(s, center).rgb;
    float3 B = tex.sample(s, center + float2(  0, -cdy)).rgb;
    float3 D = tex.sample(s, center + float2(-cdx,  0)).rgb;
    float3 F = tex.sample(s, center + float2( cdx,  0)).rgb;
    float3 H = tex.sample(s, center + float2(  0,  cdy)).rgb;
    float3 A = tex.sample(s, center + float2(-cdx, -cdy)).rgb;
    float3 C = tex.sample(s, center + float2( cdx, -cdy)).rgb;
    float3 G = tex.sample(s, center + float2(-cdx,  cdy)).rgb;
    float3 I = tex.sample(s, center + float2( cdx,  cdy)).rgb;

    // --- De-dithering: detect checkerboard pattern and blend to intermediate ---
    {
        // Checkerboard: diagonals match E, cardinals differ from E
        int diagMatch = int(hqEqual(A, E)) + int(hqEqual(C, E))
                       + int(hqEqual(G, E)) + int(hqEqual(I, E));
        int cardMatch = int(hqEqual(B, E)) + int(hqEqual(D, E))
                       + int(hqEqual(F, E)) + int(hqEqual(H, E));

        // Strong checkerboard: ≥2 diagonals match E, ≤1 cardinal matches E
        if (diagMatch >= 2 && cardMatch <= 1) {
            float3 cardAvg = (B + D + F + H) * 0.25;
            int cardConsistent = int(hqEqual(B, D)) + int(hqEqual(B, F))
                               + int(hqEqual(D, H)) + int(hqEqual(F, H));
            if (cardConsistent >= 2) {
                // Strict extension: dither must continue ≥2 pixels in ≥2 directions
                // This prevents text edges from being treated as dithering
                float3 B2 = tex.sample(s, center + float2(  0, -2.0 * cdy)).rgb;
                float3 D2 = tex.sample(s, center + float2(-2.0 * cdx,  0)).rgb;
                float3 F2 = tex.sample(s, center + float2( 2.0 * cdx,  0)).rgb;
                float3 H2 = tex.sample(s, center + float2(  0,  2.0 * cdy)).rgb;
                int extCount = int(hqEqual(B2, E)) + int(hqEqual(D2, E))
                             + int(hqEqual(F2, E)) + int(hqEqual(H2, E));
                bool extended = extCount >= 2;

                if (extended) {
                    // When black is involved, bias blend toward the brighter color
                    float lE = dot(E, float3(0.299, 0.587, 0.114));
                    float lCard = dot(cardAvg, float3(0.299, 0.587, 0.114));
                    float blendRatio;
                    if (lE < 0.05 || lCard < 0.05) {
                        blendRatio = (lE > lCard) ? 0.3 : 0.7;
                    } else {
                        blendRatio = 0.5;
                    }
                    float3 blended = mix(E, cardAvg, blendRatio);
                    return float4(blended, 1.0);
                }
            }
        }
    }

    // --- Scale2x edge detection ---
    bool tlEdge = hqEqual(B, D) && !hqEqual(B, F) && !hqEqual(D, H);
    bool trEdge = hqEqual(B, F) && !hqEqual(B, D) && !hqEqual(F, H);
    bool blEdge = hqEqual(D, H) && !hqEqual(D, B) && !hqEqual(H, F);
    bool brEdge = hqEqual(H, F) && !hqEqual(H, D) && !hqEqual(F, B);

    if (!tlEdge && !trEdge && !blEdge && !brEdge) {
        return float4(E, 1.0);
    }

    float3 result = E;

    // Linear gradient across the diagonal
    float off = params.hqOffset;
    float grad = params.hqGradient;
    float maxB = params.hqMaxBlend;

    if (tlEdge) {
        float t = clamp((1.0 + off - sp.x - sp.y) * grad, 0.0, maxB);
        result = mix(result, B, t);
    }
    if (trEdge) {
        float t = clamp((off + sp.x - sp.y) * grad, 0.0, maxB);
        result = mix(result, F, t);
    }
    if (blEdge) {
        float t = clamp((off + sp.y - sp.x) * grad, 0.0, maxB);
        result = mix(result, D, t);
    }
    if (brEdge) {
        float t = clamp((sp.x + sp.y - 1.0 + off) * grad, 0.0, maxB);
        result = mix(result, H, t);
    }

    return float4(result, 1.0);
}

// MARK: - xBRZ (GPU port of Hyllian's xBR-freescale shader)
//
// Based on: https://github.com/libretro/glsl-shaders/blob/master/xbrz/shaders/xbrz-freescale.glsl
// Copyright (C) 2011/2016 Hyllian - sergiogdb@gmail.com (MIT License)
// Also uses concepts from xBRZ by Zenju (GPL-3.0)

#define XBRZ_BLEND_NONE 0
#define XBRZ_BLEND_NORMAL 1
#define XBRZ_BLEND_DOMINANT 2
#define XBRZ_LUMINANCE_WEIGHT 1.0
#define XBRZ_EQUAL_COLOR_TOLERANCE (30.0/255.0)
#define XBRZ_STEEP_DIRECTION_THRESHOLD 2.2
#define XBRZ_DOMINANT_DIRECTION_THRESHOLD 3.6

static float xbrz_DistYCbCr(float3 pixA, float3 pixB) {
    const float3 w = float3(0.2627, 0.6780, 0.0593);
    const float scaleB = 0.5 / (1.0 - w.b);
    const float scaleR = 0.5 / (1.0 - w.r);
    float3 diff = pixA - pixB;
    float Y = dot(diff, w);
    float Cb = scaleB * (diff.b - Y);
    float Cr = scaleR * (diff.r - Y);
    return sqrt(((XBRZ_LUMINANCE_WEIGHT * Y) * (XBRZ_LUMINANCE_WEIGHT * Y)) + (Cb * Cb) + (Cr * Cr));
}

static bool xbrz_IsPixEqual(float3 pixA, float3 pixB) {
    return xbrz_DistYCbCr(pixA, pixB) < XBRZ_EQUAL_COLOR_TOLERANCE;
}

static float xbrz_get_left_ratio(float2 center, float2 origin, float2 direction, float2 scale) {
    float2 P0 = center - origin;
    float2 proj = direction * (dot(P0, direction) / dot(direction, direction));
    float2 distv = P0 - proj;
    float2 orth = float2(-direction.y, direction.x);
    float side = sign(dot(P0, orth));
    float v = side * length(distv * scale);
    // Narrow smoothstep range for sharper anti-aliasing (closer to CPU xBRZ)
    return smoothstep(-0.2, 0.2, v);
}

fragment float4 fragmentXBRZ(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler s [[sampler(0)]],
                              constant FilterParams &params [[buffer(0)]]) {
    float2 texSize = params.textureDimensions;
    float2 outSize = params.outputDimensions;
    float2 texelSize = 1.0 / texSize;

    // Amplify scale to widen anti-alias gradient (more visible at x2)
    float2 scale = outSize / texSize * 2.0;
    float2 pos = fract(in.texCoord * texSize) - float2(0.5, 0.5);
    float2 coord = in.texCoord - pos * texelSize;

    // Sample 3x3 + extended neighborhood
    #define PX(x,y) tex.sample(s, coord + texelSize * float2(x, y)).rgb
    float3 A = PX(-1,-1), B = PX(0,-1), C = PX(1,-1);
    float3 D = PX(-1, 0), E = PX(0, 0), F = PX(1, 0);
    float3 G = PX(-1, 1), H = PX(0, 1), I = PX(1, 1);

    // blendResult: x=TL, y=TR, w=BL, z=BR
    int4 blendResult = int4(XBRZ_BLEND_NONE);

    // Corner z (BR): E-F-H-I region
    if (!((xbrz_IsPixEqual(E,F) && xbrz_IsPixEqual(H,I)) || (xbrz_IsPixEqual(E,H) && xbrz_IsPixEqual(F,I)))) {
        float dist_H_F = xbrz_DistYCbCr(G,E) + xbrz_DistYCbCr(E,C) + xbrz_DistYCbCr(PX(0,2),I) + xbrz_DistYCbCr(I,PX(2,0)) + (4.0 * xbrz_DistYCbCr(H,F));
        float dist_E_I = xbrz_DistYCbCr(D,H) + xbrz_DistYCbCr(H,PX(1,2)) + xbrz_DistYCbCr(B,F) + xbrz_DistYCbCr(F,PX(2,1)) + (4.0 * xbrz_DistYCbCr(E,I));
        bool dom = (XBRZ_DOMINANT_DIRECTION_THRESHOLD * dist_H_F) < dist_E_I;
        blendResult.z = ((dist_H_F < dist_E_I) && !xbrz_IsPixEqual(E,F) && !xbrz_IsPixEqual(E,H)) ? (dom ? XBRZ_BLEND_DOMINANT : XBRZ_BLEND_NORMAL) : XBRZ_BLEND_NONE;
    }

    // Corner w (BL): D-E-G-H region
    if (!((xbrz_IsPixEqual(D,E) && xbrz_IsPixEqual(G,H)) || (xbrz_IsPixEqual(D,G) && xbrz_IsPixEqual(E,H)))) {
        float dist_G_E = xbrz_DistYCbCr(PX(-2,1),D) + xbrz_DistYCbCr(D,B) + xbrz_DistYCbCr(PX(-1,2),H) + xbrz_DistYCbCr(H,F) + (4.0 * xbrz_DistYCbCr(G,E));
        float dist_D_H = xbrz_DistYCbCr(PX(-2,0),G) + xbrz_DistYCbCr(G,PX(0,2)) + xbrz_DistYCbCr(A,E) + xbrz_DistYCbCr(E,I) + (4.0 * xbrz_DistYCbCr(D,H));
        bool dom = (XBRZ_DOMINANT_DIRECTION_THRESHOLD * dist_D_H) < dist_G_E;
        blendResult.w = ((dist_G_E > dist_D_H) && !xbrz_IsPixEqual(E,D) && !xbrz_IsPixEqual(E,H)) ? (dom ? XBRZ_BLEND_DOMINANT : XBRZ_BLEND_NORMAL) : XBRZ_BLEND_NONE;
    }

    // Corner y (TR): B-C-E-F region
    if (!((xbrz_IsPixEqual(B,C) && xbrz_IsPixEqual(E,F)) || (xbrz_IsPixEqual(B,E) && xbrz_IsPixEqual(C,F)))) {
        float dist_E_C = xbrz_DistYCbCr(D,B) + xbrz_DistYCbCr(B,PX(1,-2)) + xbrz_DistYCbCr(H,F) + xbrz_DistYCbCr(F,PX(2,-1)) + (4.0 * xbrz_DistYCbCr(E,C));
        float dist_B_F = xbrz_DistYCbCr(A,E) + xbrz_DistYCbCr(E,I) + xbrz_DistYCbCr(PX(0,-2),C) + xbrz_DistYCbCr(C,PX(2,0)) + (4.0 * xbrz_DistYCbCr(B,F));
        bool dom = (XBRZ_DOMINANT_DIRECTION_THRESHOLD * dist_B_F) < dist_E_C;
        blendResult.y = ((dist_E_C > dist_B_F) && !xbrz_IsPixEqual(E,B) && !xbrz_IsPixEqual(E,F)) ? (dom ? XBRZ_BLEND_DOMINANT : XBRZ_BLEND_NORMAL) : XBRZ_BLEND_NONE;
    }

    // Corner x (TL): A-B-D-E region
    if (!((xbrz_IsPixEqual(A,B) && xbrz_IsPixEqual(D,E)) || (xbrz_IsPixEqual(A,D) && xbrz_IsPixEqual(B,E)))) {
        float dist_D_B = xbrz_DistYCbCr(PX(-2,0),A) + xbrz_DistYCbCr(A,PX(0,-2)) + xbrz_DistYCbCr(G,E) + xbrz_DistYCbCr(E,C) + (4.0 * xbrz_DistYCbCr(D,B));
        float dist_A_E = xbrz_DistYCbCr(PX(-2,-1),D) + xbrz_DistYCbCr(D,H) + xbrz_DistYCbCr(PX(-1,-2),B) + xbrz_DistYCbCr(B,F) + (4.0 * xbrz_DistYCbCr(A,E));
        bool dom = (XBRZ_DOMINANT_DIRECTION_THRESHOLD * dist_D_B) < dist_A_E;
        blendResult.x = ((dist_D_B < dist_A_E) && !xbrz_IsPixEqual(E,D) && !xbrz_IsPixEqual(E,B)) ? (dom ? XBRZ_BLEND_DOMINANT : XBRZ_BLEND_NORMAL) : XBRZ_BLEND_NONE;
    }

    float3 res = E;

    // BR corner blend
    if (blendResult.z != XBRZ_BLEND_NONE) {
        float dist_F_G = xbrz_DistYCbCr(F, G);
        float dist_H_C = xbrz_DistYCbCr(H, C);
        bool doLine = (blendResult.z == XBRZ_BLEND_DOMINANT ||
            !((blendResult.y != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, G)) ||
              (blendResult.w != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, C)) ||
              (xbrz_IsPixEqual(G,H) && xbrz_IsPixEqual(H,I) && xbrz_IsPixEqual(I,F) && xbrz_IsPixEqual(F,C) && !xbrz_IsPixEqual(E,I))));
        float2 origin = float2(0.0, 1.0 / M_SQRT2_F);
        float2 dir = float2(1.0, -1.0);
        if (doLine) {
            bool shallow = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_F_G <= dist_H_C) && !xbrz_IsPixEqual(E,G) && !xbrz_IsPixEqual(D,G);
            bool steep = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_H_C <= dist_F_G) && !xbrz_IsPixEqual(E,C) && !xbrz_IsPixEqual(B,C);
            origin = shallow ? float2(0.0, 0.25) : float2(0.0, 0.5);
            dir.x += shallow ? 1.0 : 0.0;
            dir.y -= steep ? 1.0 : 0.0;
        }
        float3 blendPix = mix(H, F, step(xbrz_DistYCbCr(E,F), xbrz_DistYCbCr(E,H)));
        res = mix(res, blendPix, xbrz_get_left_ratio(pos, origin, dir, scale));
    }

    // BL corner blend
    if (blendResult.w != XBRZ_BLEND_NONE) {
        float dist_H_A = xbrz_DistYCbCr(H, A);
        float dist_D_I = xbrz_DistYCbCr(D, I);
        bool doLine = (blendResult.w == XBRZ_BLEND_DOMINANT ||
            !((blendResult.z != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, A)) ||
              (blendResult.x != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, I)) ||
              (xbrz_IsPixEqual(A,D) && xbrz_IsPixEqual(D,G) && xbrz_IsPixEqual(G,H) && xbrz_IsPixEqual(H,I) && !xbrz_IsPixEqual(E,G))));
        float2 origin = float2(-1.0 / M_SQRT2_F, 0.0);
        float2 dir = float2(1.0, 1.0);
        if (doLine) {
            bool shallow = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_H_A <= dist_D_I) && !xbrz_IsPixEqual(E,A) && !xbrz_IsPixEqual(B,A);
            bool steep = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_D_I <= dist_H_A) && !xbrz_IsPixEqual(E,I) && !xbrz_IsPixEqual(F,I);
            origin = shallow ? float2(-0.25, 0.0) : float2(-0.5, 0.0);
            dir.y += shallow ? 1.0 : 0.0;
            dir.x += steep ? 1.0 : 0.0;
        }
        float3 blendPix = mix(H, D, step(xbrz_DistYCbCr(E,D), xbrz_DistYCbCr(E,H)));
        res = mix(res, blendPix, xbrz_get_left_ratio(pos, origin, dir, scale));
    }

    // TR corner blend
    if (blendResult.y != XBRZ_BLEND_NONE) {
        float dist_B_I = xbrz_DistYCbCr(B, I);
        float dist_F_A = xbrz_DistYCbCr(F, A);
        bool doLine = (blendResult.y == XBRZ_BLEND_DOMINANT ||
            !((blendResult.x != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, I)) ||
              (blendResult.z != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, A)) ||
              (xbrz_IsPixEqual(I,F) && xbrz_IsPixEqual(F,C) && xbrz_IsPixEqual(C,B) && xbrz_IsPixEqual(B,A) && !xbrz_IsPixEqual(E,C))));
        float2 origin = float2(1.0 / M_SQRT2_F, 0.0);
        float2 dir = float2(-1.0, -1.0);
        if (doLine) {
            bool shallow = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_B_I <= dist_F_A) && !xbrz_IsPixEqual(E,I) && !xbrz_IsPixEqual(H,I);
            bool steep = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_F_A <= dist_B_I) && !xbrz_IsPixEqual(E,A) && !xbrz_IsPixEqual(D,A);
            origin = shallow ? float2(0.25, 0.0) : float2(0.5, 0.0);
            dir.y -= shallow ? 1.0 : 0.0;
            dir.x -= steep ? 1.0 : 0.0;
        }
        float3 blendPix = mix(F, B, step(xbrz_DistYCbCr(E,B), xbrz_DistYCbCr(E,F)));
        res = mix(res, blendPix, xbrz_get_left_ratio(pos, origin, dir, scale));
    }

    // TL corner blend
    if (blendResult.x != XBRZ_BLEND_NONE) {
        float dist_D_C = xbrz_DistYCbCr(D, C);
        float dist_B_G = xbrz_DistYCbCr(B, G);
        bool doLine = (blendResult.x == XBRZ_BLEND_DOMINANT ||
            !((blendResult.w != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, C)) ||
              (blendResult.y != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, G)) ||
              (xbrz_IsPixEqual(C,B) && xbrz_IsPixEqual(B,A) && xbrz_IsPixEqual(A,D) && xbrz_IsPixEqual(D,G) && !xbrz_IsPixEqual(E,A))));
        float2 origin = float2(0.0, -1.0 / M_SQRT2_F);
        float2 dir = float2(-1.0, 1.0);
        if (doLine) {
            bool shallow = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_D_C <= dist_B_G) && !xbrz_IsPixEqual(E,C) && !xbrz_IsPixEqual(F,C);
            bool steep = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_B_G <= dist_D_C) && !xbrz_IsPixEqual(E,G) && !xbrz_IsPixEqual(H,G);
            origin = shallow ? float2(0.0, -0.25) : float2(0.0, -0.5);
            dir.x -= shallow ? 1.0 : 0.0;
            dir.y += steep ? 1.0 : 0.0;
        }
        float3 blendPix = mix(D, B, step(xbrz_DistYCbCr(E,B), xbrz_DistYCbCr(E,D)));
        res = mix(res, blendPix, xbrz_get_left_ratio(pos, origin, dir, scale));
    }

    #undef PX
    return float4(res, 1.0);
}


