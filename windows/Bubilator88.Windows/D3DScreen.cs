using System;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Controls;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.Mathematics;
using WinRT;
using static Vortice.Direct3D11.D3D11;

namespace Bubilator88.Windows;

/// <summary>Video filter selection (mirrors the macOS EmulatorViewModel.VideoFilter).
/// <c>Ai</c> is the Quality tier (Real-ESRGAN x2) run via ONNX Runtime + DirectML;
/// the macOS Fast/Balanced tiers are not (yet) ported.</summary>
internal enum ScreenFilter { None, Linear, Bicubic, Crt, Xbrz, Enhanced, Ai }

/// <summary>
/// Direct3D 11 presenter for the 640×400 emulator frame, composited onto a
/// WinUI 3 <see cref="SwapChainPanel"/>. Mirrors the macOS Metal pipeline
/// (Display.metal / EmulatorMetalView): a dynamic source texture is updated each
/// frame from the core's RGBA buffer and drawn through the selected video filter
/// (None/Linear/Bicubic/CRT/xBRZ/Enhanced) plus optional scanlines.
///
/// <para>Like macOS, filters operate at real content resolution: in 200-line mode
/// the even rows are extracted into a 640×200 texture before filtering (the core
/// buffer is always 640×400 row-doubled). CRT runs a 2-pass phosphor-persistence
/// path (accumulate → composite) and Enhanced runs HQ de-dithering → xBRZ, both
/// matching the macOS multi-pass rendering exactly.</para>
/// </summary>
internal sealed unsafe class D3DScreen : IDisposable
{
    [ComImport, Guid("63aad0b8-7c24-40ff-85a8-640d944cc325"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISwapChainPanelNative
    {
        [PreserveSig] int SetSwapChain(IntPtr swapChain);
    }

    // All shader entry points live in one source. Ported verbatim from
    // Bubilator88/Rendering/Display.metal — Metal→HLSL: mix→lerp, fract→frac,
    // texture.sample→Tex.Sample, FilterParams struct → cbuffer b0. Kept
    // line-for-line equivalent so Windows and macOS render identically.
    private const string Hlsl = """
        Texture2D    Tex  : register(t0);
        Texture2D    Prev : register(t1);
        SamplerState Smp  : register(s0);

        cbuffer FilterParams : register(b0) {
            float2 textureDimensions;
            float2 outputDimensions;
            uint   scanlineEnabled;
            uint   is400LineMode;
            float  hqOffset;
            float  hqGradient;
            float  hqMaxBlend;
            float  hqPadding;
            float  persistR;
            float  persistG;
            float  persistB;
            float  persistPad;
        };

        struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };

        VSOut VSMain(uint vid : SV_VertexID) {
            VSOut o;
            float2 uv = float2((vid << 1) & 2, vid & 2);
            o.uv  = uv;
            o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
            return o;
        }

        float scanlineMultiplier(float2 uv) {
            if (scanlineEnabled == 0) return 1.0;
            float srcY = uv.y * textureDimensions.y;
            if (textureDimensions.y > 300.0) {
                return step(1.0, fmod(srcY, 2.0)) < 0.5 ? 1.0 : 0.3;
            } else {
                return frac(srcY) >= 0.5 ? 0.3 : 1.0;
            }
        }

        // --- None / Linear (sampler differs; shader identical) ---
        float4 PSNearest(VSOut i) : SV_Target {
            float4 c = Tex.Sample(Smp, i.uv);
            float sl = scanlineMultiplier(i.uv);
            return float4(c.rgb * sl, 1.0);
        }

        // --- Bicubic (Catmull-Rom) ---
        float catmullRomWeight(float x) {
            float ax = abs(x);
            if (ax <= 1.0) {
                return 0.5 * ((2.0 - 5.0 * ax * ax + 3.0 * ax * ax * ax));
            } else if (ax <= 2.0) {
                return 0.5 * (4.0 - 8.0 * ax + 5.0 * ax * ax - ax * ax * ax);
            }
            return 0.0;
        }
        float4 PSBicubic(VSOut i) : SV_Target {
            float2 texSize = textureDimensions;
            float2 texelSize = 1.0 / texSize;
            float2 coord = i.uv * texSize - 0.5;
            float2 f = frac(coord);
            float2 base = (floor(coord) + 0.5) * texelSize;
            float4 result = float4(0,0,0,0);
            float weightSum = 0.0;
            for (int y = -1; y <= 2; y++) {
                float wy = catmullRomWeight(float(y) - f.y);
                for (int x = -1; x <= 2; x++) {
                    float wx = catmullRomWeight(float(x) - f.x);
                    float w = wx * wy;
                    float2 sc = base + float2(float(x), float(y)) * texelSize;
                    result += Tex.Sample(Smp, sc) * w;
                    weightSum += w;
                }
            }
            result /= weightSum;
            float sl = scanlineMultiplier(i.uv);
            return float4(result.rgb * sl, 1.0);
        }

        // --- CRT phosphor accumulate (pass 1): current + decayed previous ---
        float4 PSCRTAccumulate(VSOut i) : SV_Target {
            float2 uv = i.uv;
            float4 color = Tex.Sample(Smp, uv);
            float srcY = uv.y * textureDimensions.y;
            float isGap;
            if (textureDimensions.y > 300.0) {
                isGap = step(1.0, fmod(srcY, 2.0));
            } else {
                isGap = step(0.5, frac(srcY));
            }
            float brightness = dot(color.rgb, float3(0.299, 0.587, 0.114));
            float gapLevel = lerp(0.55, 0.80, brightness);
            float scanline = (isGap > 0.5) ? gapLevel : 1.0;
            color.rgb *= scanline;
            color.rgb *= 1.08;
            color.b   *= 0.95;
            float3 prev = Prev.Sample(Smp, uv).rgb;
            float3 decayed = prev * float3(persistR, persistG, persistB);
            float3 result = max(color.rgb, decayed);
            return float4(clamp(result, 0.0, 1.0), 1.0);
        }

        // --- CRT composite (pass 2): vignette → screen ---
        float4 PSCRTComposite(VSOut i) : SV_Target {
            float4 color = Tex.Sample(Smp, i.uv);
            float2 vig = i.uv * 2.0 - 1.0;
            float vignette = 1.0 - smoothstep(1.2, 2.0, length(vig));
            color.rgb *= vignette;
            return float4(clamp(color.rgb, 0.0, 1.0), 1.0);
        }

        // --- High Quality (Scale2x-inspired sub-pixel edge smoothing + de-dither) ---
        bool hqEqual(float3 a, float3 b) {
            float3 d = a - b;
            return dot(d, d) < 0.01;
        }
        float4 PSHighQuality(VSOut i) : SV_Target {
            float2 texSize = textureDimensions;
            float contentW = texSize.x;
            float contentH = texSize.y;
            float2 contentCoord = float2(i.uv.x * contentW, i.uv.y * contentH);
            float2 contentTexel = floor(contentCoord);
            float2 sp = contentCoord - contentTexel;
            float2 center = float2((contentTexel.x + 0.5) / contentW,
                                   (contentTexel.y + 0.5) / contentH);
            float cdx = 1.0 / contentW;
            float cdy = 1.0 / contentH;

            float scale = outputDimensions.x / contentW;
            if (scale < 1.5) {
                float3 E0 = Tex.Sample(Smp, center).rgb;
                return float4(E0, 1.0);
            }

            float3 E = Tex.Sample(Smp, center).rgb;
            float3 B = Tex.Sample(Smp, center + float2(  0, -cdy)).rgb;
            float3 D = Tex.Sample(Smp, center + float2(-cdx,  0)).rgb;
            float3 F = Tex.Sample(Smp, center + float2( cdx,  0)).rgb;
            float3 H = Tex.Sample(Smp, center + float2(  0,  cdy)).rgb;
            float3 A = Tex.Sample(Smp, center + float2(-cdx, -cdy)).rgb;
            float3 C = Tex.Sample(Smp, center + float2( cdx, -cdy)).rgb;
            float3 G = Tex.Sample(Smp, center + float2(-cdx,  cdy)).rgb;
            float3 I = Tex.Sample(Smp, center + float2( cdx,  cdy)).rgb;

            {
                int diagMatch = (int)hqEqual(A, E) + (int)hqEqual(C, E)
                              + (int)hqEqual(G, E) + (int)hqEqual(I, E);
                int cardMatch = (int)hqEqual(B, E) + (int)hqEqual(D, E)
                              + (int)hqEqual(F, E) + (int)hqEqual(H, E);
                if (diagMatch >= 2 && cardMatch <= 1) {
                    float3 cardAvg = (B + D + F + H) * 0.25;
                    int cardConsistent = (int)hqEqual(B, D) + (int)hqEqual(B, F)
                                       + (int)hqEqual(D, H) + (int)hqEqual(F, H);
                    if (cardConsistent >= 2) {
                        float3 B2 = Tex.Sample(Smp, center + float2(  0, -2.0 * cdy)).rgb;
                        float3 D2 = Tex.Sample(Smp, center + float2(-2.0 * cdx,  0)).rgb;
                        float3 F2 = Tex.Sample(Smp, center + float2( 2.0 * cdx,  0)).rgb;
                        float3 H2 = Tex.Sample(Smp, center + float2(  0,  2.0 * cdy)).rgb;
                        int extCount = (int)hqEqual(B2, E) + (int)hqEqual(D2, E)
                                     + (int)hqEqual(F2, E) + (int)hqEqual(H2, E);
                        if (extCount >= 2) {
                            float lE = dot(E, float3(0.299, 0.587, 0.114));
                            float lCard = dot(cardAvg, float3(0.299, 0.587, 0.114));
                            float blendRatio;
                            if (lE < 0.05 || lCard < 0.05) {
                                blendRatio = (lE > lCard) ? 0.3 : 0.7;
                            } else {
                                blendRatio = 0.5;
                            }
                            float3 blended = lerp(E, cardAvg, blendRatio);
                            return float4(blended, 1.0);
                        }
                    }
                }
            }

            bool tlEdge = hqEqual(B, D) && !hqEqual(B, F) && !hqEqual(D, H);
            bool trEdge = hqEqual(B, F) && !hqEqual(B, D) && !hqEqual(F, H);
            bool blEdge = hqEqual(D, H) && !hqEqual(D, B) && !hqEqual(H, F);
            bool brEdge = hqEqual(H, F) && !hqEqual(H, D) && !hqEqual(F, B);

            if (!tlEdge && !trEdge && !blEdge && !brEdge) {
                return float4(E, 1.0);
            }

            float3 result = E;
            float off = hqOffset;
            float grad = hqGradient;
            float maxB = hqMaxBlend;

            if (tlEdge) {
                float t = clamp((1.0 + off - sp.x - sp.y) * grad, 0.0, maxB);
                result = lerp(result, B, t);
            }
            if (trEdge) {
                float t = clamp((off + sp.x - sp.y) * grad, 0.0, maxB);
                result = lerp(result, F, t);
            }
            if (blEdge) {
                float t = clamp((off + sp.y - sp.x) * grad, 0.0, maxB);
                result = lerp(result, D, t);
            }
            if (brEdge) {
                float t = clamp((sp.x + sp.y - 1.0 + off) * grad, 0.0, maxB);
                result = lerp(result, H, t);
            }
            return float4(result, 1.0);
        }

        // --- xBRZ (GPU port of Hyllian's xBR-freescale; also Enhanced pass 2) ---
        #define XBRZ_BLEND_NONE 0
        #define XBRZ_BLEND_NORMAL 1
        #define XBRZ_BLEND_DOMINANT 2
        #define XBRZ_LUMINANCE_WEIGHT 1.0
        #define XBRZ_EQUAL_COLOR_TOLERANCE (30.0/255.0)
        #define XBRZ_STEEP_DIRECTION_THRESHOLD 2.2
        #define XBRZ_DOMINANT_DIRECTION_THRESHOLD 3.6
        #define XBRZ_M_SQRT2 1.41421356

        float xbrz_DistYCbCr(float3 pixA, float3 pixB) {
            const float3 w = float3(0.2627, 0.6780, 0.0593);
            const float scaleB = 0.5 / (1.0 - w.b);
            const float scaleR = 0.5 / (1.0 - w.r);
            float3 diff = pixA - pixB;
            float Y = dot(diff, w);
            float Cb = scaleB * (diff.b - Y);
            float Cr = scaleR * (diff.r - Y);
            return sqrt(((XBRZ_LUMINANCE_WEIGHT * Y) * (XBRZ_LUMINANCE_WEIGHT * Y)) + (Cb * Cb) + (Cr * Cr));
        }
        bool xbrz_IsPixEqual(float3 pixA, float3 pixB) {
            return xbrz_DistYCbCr(pixA, pixB) < XBRZ_EQUAL_COLOR_TOLERANCE;
        }
        float xbrz_get_left_ratio(float2 center, float2 origin, float2 direction, float2 scale) {
            float2 P0 = center - origin;
            float2 proj = direction * (dot(P0, direction) / dot(direction, direction));
            float2 distv = P0 - proj;
            float2 orth = float2(-direction.y, direction.x);
            float side = sign(dot(P0, orth));
            float v = side * length(distv * scale);
            return smoothstep(-0.2, 0.2, v);
        }
        float4 PSXBRZ(VSOut inp) : SV_Target {
            float2 texSize = textureDimensions;
            float2 outSize = outputDimensions;
            float2 texelSize = 1.0 / texSize;
            float2 scale = outSize / texSize * 2.0;
            float2 pos = frac(inp.uv * texSize) - float2(0.5, 0.5);
            float2 coord = inp.uv - pos * texelSize;

            #define PX(x,y) Tex.Sample(Smp, coord + texelSize * float2(x, y)).rgb
            float3 A = PX(-1,-1), B = PX(0,-1), C = PX(1,-1);
            float3 D = PX(-1, 0), E = PX(0, 0), F = PX(1, 0);
            float3 G = PX(-1, 1), H = PX(0, 1), I = PX(1, 1);

            int4 blendResult = int4(0,0,0,0);

            if (!((xbrz_IsPixEqual(E,F) && xbrz_IsPixEqual(H,I)) || (xbrz_IsPixEqual(E,H) && xbrz_IsPixEqual(F,I)))) {
                float dist_H_F = xbrz_DistYCbCr(G,E) + xbrz_DistYCbCr(E,C) + xbrz_DistYCbCr(PX(0,2),I) + xbrz_DistYCbCr(I,PX(2,0)) + (4.0 * xbrz_DistYCbCr(H,F));
                float dist_E_I = xbrz_DistYCbCr(D,H) + xbrz_DistYCbCr(H,PX(1,2)) + xbrz_DistYCbCr(B,F) + xbrz_DistYCbCr(F,PX(2,1)) + (4.0 * xbrz_DistYCbCr(E,I));
                bool dom = (XBRZ_DOMINANT_DIRECTION_THRESHOLD * dist_H_F) < dist_E_I;
                blendResult.z = ((dist_H_F < dist_E_I) && !xbrz_IsPixEqual(E,F) && !xbrz_IsPixEqual(E,H)) ? (dom ? XBRZ_BLEND_DOMINANT : XBRZ_BLEND_NORMAL) : XBRZ_BLEND_NONE;
            }
            if (!((xbrz_IsPixEqual(D,E) && xbrz_IsPixEqual(G,H)) || (xbrz_IsPixEqual(D,G) && xbrz_IsPixEqual(E,H)))) {
                float dist_G_E = xbrz_DistYCbCr(PX(-2,1),D) + xbrz_DistYCbCr(D,B) + xbrz_DistYCbCr(PX(-1,2),H) + xbrz_DistYCbCr(H,F) + (4.0 * xbrz_DistYCbCr(G,E));
                float dist_D_H = xbrz_DistYCbCr(PX(-2,0),G) + xbrz_DistYCbCr(G,PX(0,2)) + xbrz_DistYCbCr(A,E) + xbrz_DistYCbCr(E,I) + (4.0 * xbrz_DistYCbCr(D,H));
                bool dom = (XBRZ_DOMINANT_DIRECTION_THRESHOLD * dist_D_H) < dist_G_E;
                blendResult.w = ((dist_G_E > dist_D_H) && !xbrz_IsPixEqual(E,D) && !xbrz_IsPixEqual(E,H)) ? (dom ? XBRZ_BLEND_DOMINANT : XBRZ_BLEND_NORMAL) : XBRZ_BLEND_NONE;
            }
            if (!((xbrz_IsPixEqual(B,C) && xbrz_IsPixEqual(E,F)) || (xbrz_IsPixEqual(B,E) && xbrz_IsPixEqual(C,F)))) {
                float dist_E_C = xbrz_DistYCbCr(D,B) + xbrz_DistYCbCr(B,PX(1,-2)) + xbrz_DistYCbCr(H,F) + xbrz_DistYCbCr(F,PX(2,-1)) + (4.0 * xbrz_DistYCbCr(E,C));
                float dist_B_F = xbrz_DistYCbCr(A,E) + xbrz_DistYCbCr(E,I) + xbrz_DistYCbCr(PX(0,-2),C) + xbrz_DistYCbCr(C,PX(2,0)) + (4.0 * xbrz_DistYCbCr(B,F));
                bool dom = (XBRZ_DOMINANT_DIRECTION_THRESHOLD * dist_B_F) < dist_E_C;
                blendResult.y = ((dist_E_C > dist_B_F) && !xbrz_IsPixEqual(E,B) && !xbrz_IsPixEqual(E,F)) ? (dom ? XBRZ_BLEND_DOMINANT : XBRZ_BLEND_NORMAL) : XBRZ_BLEND_NONE;
            }
            if (!((xbrz_IsPixEqual(A,B) && xbrz_IsPixEqual(D,E)) || (xbrz_IsPixEqual(A,D) && xbrz_IsPixEqual(B,E)))) {
                float dist_D_B = xbrz_DistYCbCr(PX(-2,0),A) + xbrz_DistYCbCr(A,PX(0,-2)) + xbrz_DistYCbCr(G,E) + xbrz_DistYCbCr(E,C) + (4.0 * xbrz_DistYCbCr(D,B));
                float dist_A_E = xbrz_DistYCbCr(PX(-2,-1),D) + xbrz_DistYCbCr(D,H) + xbrz_DistYCbCr(PX(-1,-2),B) + xbrz_DistYCbCr(B,F) + (4.0 * xbrz_DistYCbCr(A,E));
                bool dom = (XBRZ_DOMINANT_DIRECTION_THRESHOLD * dist_D_B) < dist_A_E;
                blendResult.x = ((dist_D_B < dist_A_E) && !xbrz_IsPixEqual(E,D) && !xbrz_IsPixEqual(E,B)) ? (dom ? XBRZ_BLEND_DOMINANT : XBRZ_BLEND_NORMAL) : XBRZ_BLEND_NONE;
            }

            float3 res = E;

            if (blendResult.z != XBRZ_BLEND_NONE) {
                float dist_F_G = xbrz_DistYCbCr(F, G);
                float dist_H_C = xbrz_DistYCbCr(H, C);
                bool doLine = (blendResult.z == XBRZ_BLEND_DOMINANT ||
                    !((blendResult.y != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, G)) ||
                      (blendResult.w != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, C)) ||
                      (xbrz_IsPixEqual(G,H) && xbrz_IsPixEqual(H,I) && xbrz_IsPixEqual(I,F) && xbrz_IsPixEqual(F,C) && !xbrz_IsPixEqual(E,I))));
                float2 origin = float2(0.0, 1.0 / XBRZ_M_SQRT2);
                float2 dir = float2(1.0, -1.0);
                if (doLine) {
                    bool shallow = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_F_G <= dist_H_C) && !xbrz_IsPixEqual(E,G) && !xbrz_IsPixEqual(D,G);
                    bool steep = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_H_C <= dist_F_G) && !xbrz_IsPixEqual(E,C) && !xbrz_IsPixEqual(B,C);
                    origin = shallow ? float2(0.0, 0.25) : float2(0.0, 0.5);
                    dir.x += shallow ? 1.0 : 0.0;
                    dir.y -= steep ? 1.0 : 0.0;
                }
                float3 blendPix = lerp(H, F, step(xbrz_DistYCbCr(E,F), xbrz_DistYCbCr(E,H)));
                res = lerp(res, blendPix, xbrz_get_left_ratio(pos, origin, dir, scale));
            }
            if (blendResult.w != XBRZ_BLEND_NONE) {
                float dist_H_A = xbrz_DistYCbCr(H, A);
                float dist_D_I = xbrz_DistYCbCr(D, I);
                bool doLine = (blendResult.w == XBRZ_BLEND_DOMINANT ||
                    !((blendResult.z != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, A)) ||
                      (blendResult.x != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, I)) ||
                      (xbrz_IsPixEqual(A,D) && xbrz_IsPixEqual(D,G) && xbrz_IsPixEqual(G,H) && xbrz_IsPixEqual(H,I) && !xbrz_IsPixEqual(E,G))));
                float2 origin = float2(-1.0 / XBRZ_M_SQRT2, 0.0);
                float2 dir = float2(1.0, 1.0);
                if (doLine) {
                    bool shallow = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_H_A <= dist_D_I) && !xbrz_IsPixEqual(E,A) && !xbrz_IsPixEqual(B,A);
                    bool steep = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_D_I <= dist_H_A) && !xbrz_IsPixEqual(E,I) && !xbrz_IsPixEqual(F,I);
                    origin = shallow ? float2(-0.25, 0.0) : float2(-0.5, 0.0);
                    dir.y += shallow ? 1.0 : 0.0;
                    dir.x += steep ? 1.0 : 0.0;
                }
                float3 blendPix = lerp(H, D, step(xbrz_DistYCbCr(E,D), xbrz_DistYCbCr(E,H)));
                res = lerp(res, blendPix, xbrz_get_left_ratio(pos, origin, dir, scale));
            }
            if (blendResult.y != XBRZ_BLEND_NONE) {
                float dist_B_I = xbrz_DistYCbCr(B, I);
                float dist_F_A = xbrz_DistYCbCr(F, A);
                bool doLine = (blendResult.y == XBRZ_BLEND_DOMINANT ||
                    !((blendResult.x != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, I)) ||
                      (blendResult.z != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, A)) ||
                      (xbrz_IsPixEqual(I,F) && xbrz_IsPixEqual(F,C) && xbrz_IsPixEqual(C,B) && xbrz_IsPixEqual(B,A) && !xbrz_IsPixEqual(E,C))));
                float2 origin = float2(1.0 / XBRZ_M_SQRT2, 0.0);
                float2 dir = float2(-1.0, -1.0);
                if (doLine) {
                    bool shallow = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_B_I <= dist_F_A) && !xbrz_IsPixEqual(E,I) && !xbrz_IsPixEqual(H,I);
                    bool steep = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_F_A <= dist_B_I) && !xbrz_IsPixEqual(E,A) && !xbrz_IsPixEqual(D,A);
                    origin = shallow ? float2(0.25, 0.0) : float2(0.5, 0.0);
                    dir.y -= shallow ? 1.0 : 0.0;
                    dir.x -= steep ? 1.0 : 0.0;
                }
                float3 blendPix = lerp(F, B, step(xbrz_DistYCbCr(E,B), xbrz_DistYCbCr(E,F)));
                res = lerp(res, blendPix, xbrz_get_left_ratio(pos, origin, dir, scale));
            }
            if (blendResult.x != XBRZ_BLEND_NONE) {
                float dist_D_C = xbrz_DistYCbCr(D, C);
                float dist_B_G = xbrz_DistYCbCr(B, G);
                bool doLine = (blendResult.x == XBRZ_BLEND_DOMINANT ||
                    !((blendResult.w != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, C)) ||
                      (blendResult.y != XBRZ_BLEND_NONE && !xbrz_IsPixEqual(E, G)) ||
                      (xbrz_IsPixEqual(C,B) && xbrz_IsPixEqual(B,A) && xbrz_IsPixEqual(A,D) && xbrz_IsPixEqual(D,G) && !xbrz_IsPixEqual(E,A))));
                float2 origin = float2(0.0, -1.0 / XBRZ_M_SQRT2);
                float2 dir = float2(-1.0, 1.0);
                if (doLine) {
                    bool shallow = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_D_C <= dist_B_G) && !xbrz_IsPixEqual(E,C) && !xbrz_IsPixEqual(F,C);
                    bool steep = (XBRZ_STEEP_DIRECTION_THRESHOLD * dist_B_G <= dist_D_C) && !xbrz_IsPixEqual(E,G) && !xbrz_IsPixEqual(H,G);
                    origin = shallow ? float2(0.0, -0.25) : float2(0.0, -0.5);
                    dir.x -= shallow ? 1.0 : 0.0;
                    dir.y += steep ? 1.0 : 0.0;
                }
                float3 blendPix = lerp(D, B, step(xbrz_DistYCbCr(E,B), xbrz_DistYCbCr(E,D)));
                res = lerp(res, blendPix, xbrz_get_left_ratio(pos, origin, dir, scale));
            }
            #undef PX
            return float4(res, 1.0);
        }
        """;

    [StructLayout(LayoutKind.Sequential)]
    private struct FilterParams
    {
        public float TexW, TexH;
        public float OutW, OutH;
        public uint Scanline;
        public uint Is400;
        public float HqOffset, HqGradient, HqMaxBlend, HqPadding;
        public float PersistR, PersistG, PersistB, PersistPad;
    }

    // macOS HQ debug defaults (EmulatorViewModel.hqOffset/Gradient/MaxBlend).
    private const float HqOffset = 0.05f;
    private const float HqGradient = 0.3f;
    private const float HqMaxBlend = 0.3f;
    // P22 phosphor decay (EmulatorMetalView crtAccumulate params).
    private const float PersistR = 0.55f, PersistG = 0.50f, PersistB = 0.30f;

    private const int Content200Height = 200;

    private readonly int _srcWidth;    // 640
    private readonly int _srcHeight;    // 400

    private ID3D11Device _device = null!;
    private ID3D11DeviceContext _ctx = null!;
    private IDXGISwapChain1 _swapChain = null!;
    private ID3D11RenderTargetView _rtv = null!;

    private ID3D11Texture2D _srcTex400 = null!;       // 640×400 upload
    private ID3D11ShaderResourceView _srv400 = null!;
    private ID3D11Texture2D _srcTex200 = null!;       // 640×200 content (200-line)
    private ID3D11ShaderResourceView _srv200 = null!;

    // Offscreen render targets for the multi-pass filters.
    private ID3D11Texture2D _intermediate = null!;    // 640×200 (Enhanced HQ pass)
    private ID3D11RenderTargetView _intermediateRtv = null!;
    private ID3D11ShaderResourceView _intermediateSrv = null!;
    private ID3D11Texture2D _persistA = null!, _persistB = null!;   // 640×400 ping-pong
    private ID3D11RenderTargetView _persistARtv = null!, _persistBRtv = null!;
    private ID3D11ShaderResourceView _persistASrv = null!, _persistBSrv = null!;
    private bool _persistFlip;
    private bool _persistPrimed;
    // Most recently accumulated CRT persistence SRV (the on-screen result), and
    // the last line mode — used by CaptureFiltered to reproduce what's displayed.
    private ID3D11ShaderResourceView? _recentPersistSrv;
    private bool _lastIs400Line;

    private ID3D11SamplerState _pointSampler = null!;
    private ID3D11SamplerState _linearSampler = null!;
    private ID3D11Buffer _cbuffer = null!;

    private ID3D11VertexShader _vs = null!;
    private ID3D11PixelShader _psNearest = null!;
    private ID3D11PixelShader _psBicubic = null!;
    private ID3D11PixelShader _psCrtAccumulate = null!;
    private ID3D11PixelShader _psCrtComposite = null!;
    private ID3D11PixelShader _psHighQuality = null!;
    private ID3D11PixelShader _psXbrz = null!;

    private byte[] _src200 = Array.Empty<byte>();   // even-row extraction scratch

    // AI upscale (Quality / Real-ESRGAN x2). The upscaler infers asynchronously;
    // its 1280×800 RGBA output is uploaded into _aiTex on the UI thread whenever a
    // newer frame is ready (tracked by _aiUploadedVersion). Lazily created the
    // first time the AI filter is selected.
    private AiUpscaler? _ai;
    private ID3D11Texture2D? _aiTex;                 // 1280×800 upload
    private ID3D11ShaderResourceView? _aiSrv;
    private long _aiUploadedVersion;
    private bool _aiHasUpload;

    private ScreenFilter _filter = ScreenFilter.None;
    private bool _scanlineEnabled;

    private int _width;
    private int _height;

    public D3DScreen(SwapChainPanel panel, int srcWidth, int srcHeight)
    {
        _srcWidth = srcWidth;
        _srcHeight = srcHeight;
        _width = Math.Max(1, (int)(panel.ActualWidth * panel.CompositionScaleX));
        _height = Math.Max(1, (int)(panel.ActualHeight * panel.CompositionScaleY));

        D3D11CreateDevice(
            null, DriverType.Hardware,
            DeviceCreationFlags.BgraSupport,
            new[] { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0 },
            out _device, out _ctx).CheckError();

        using var dxgiDevice = _device.QueryInterface<IDXGIDevice>();
        using var adapter = dxgiDevice.GetAdapter();
        using var factory = adapter.GetParent<IDXGIFactory2>();

        var scd = new SwapChainDescription1
        {
            Width = (uint)_width,
            Height = (uint)_height,
            Format = Format.B8G8R8A8_UNorm,
            Stereo = false,
            SampleDescription = new SampleDescription(1, 0),
            BufferUsage = Usage.RenderTargetOutput,
            BufferCount = 2,
            Scaling = Scaling.Stretch,
            SwapEffect = SwapEffect.FlipSequential,
            AlphaMode = AlphaMode.Premultiplied,
        };
        _swapChain = factory.CreateSwapChainForComposition(_device, scd);

        var nativePanel = panel.As<ISwapChainPanelNative>();
        int hr = nativePanel.SetSwapChain(_swapChain.NativePointer);
        if (hr < 0) Marshal.ThrowExceptionForHR(hr);

        CreateRenderTarget();
        CreateTextures();
        CreatePipeline();
    }

    /// <summary>Select the active video filter + scanline state (host menu).</summary>
    public void SetFilter(ScreenFilter filter, bool scanlineEnabled)
    {
        // Reset phosphor persistence when entering CRT so no stale ghost frame
        // bleeds in (matches macOS updateVideoFilter).
        if (filter == ScreenFilter.Crt && _filter != ScreenFilter.Crt)
            _persistPrimed = false;

        if (filter == ScreenFilter.Ai && _filter != ScreenFilter.Ai)
        {
            // Lazily spin up the upscaler + kick off model load (idempotent).
            _ai ??= new AiUpscaler();
            _ai.EnsureLoaded();
        }
        else if (filter != ScreenFilter.Ai && _filter == ScreenFilter.Ai)
        {
            // Leaving AI: drop pending/completed output so a stale frame can't
            // resurface on re-entry (the session stays loaded for fast re-entry).
            _ai?.Reset();
            _aiHasUpload = false;
            _aiUploadedVersion = 0;
        }

        _filter = filter;
        _scanlineEnabled = scanlineEnabled;
    }

    private void CreateRenderTarget()
    {
        using var backbuffer = _swapChain.GetBuffer<ID3D11Texture2D>(0);
        _rtv = _device.CreateRenderTargetView(backbuffer);
    }

    private ID3D11Texture2D MakeDynamic(int w, int h)
        => _device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)w,
            Height = (uint)h,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.R8G8B8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Dynamic,
            BindFlags = BindFlags.ShaderResource,
            CPUAccessFlags = CpuAccessFlags.Write,
        });

    private ID3D11Texture2D MakeRenderTarget(int w, int h)
        => _device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)w,
            Height = (uint)h,
            MipLevels = 1,
            ArraySize = 1,
            Format = Format.R8G8B8A8_UNorm,
            SampleDescription = new SampleDescription(1, 0),
            Usage = ResourceUsage.Default,
            BindFlags = BindFlags.ShaderResource | BindFlags.RenderTarget,
            CPUAccessFlags = CpuAccessFlags.None,
        });

    private void CreateTextures()
    {
        _srcTex400 = MakeDynamic(_srcWidth, _srcHeight);
        _srv400 = _device.CreateShaderResourceView(_srcTex400);
        _srcTex200 = MakeDynamic(_srcWidth, Content200Height);
        _srv200 = _device.CreateShaderResourceView(_srcTex200);

        _intermediate = MakeRenderTarget(_srcWidth, Content200Height);
        _intermediateRtv = _device.CreateRenderTargetView(_intermediate);
        _intermediateSrv = _device.CreateShaderResourceView(_intermediate);

        _persistA = MakeRenderTarget(_srcWidth, _srcHeight);
        _persistARtv = _device.CreateRenderTargetView(_persistA);
        _persistASrv = _device.CreateShaderResourceView(_persistA);
        _persistB = MakeRenderTarget(_srcWidth, _srcHeight);
        _persistBRtv = _device.CreateRenderTargetView(_persistB);
        _persistBSrv = _device.CreateShaderResourceView(_persistB);

        _src200 = new byte[_srcWidth * Content200Height * 4];
    }

    private void CreatePipeline()
    {
        // NB: the trailing "\n" is required — Vortice's Compile(string,…) drops
        // the final source byte, so without it the last "}" is lost and the
        // HLSL fails with X3000 "unexpected end of file" (verified against
        // Vortice.D3DCompiler directly). A newline makes the dropped byte
        // harmless.
        ReadOnlyMemory<byte> Compile(string entry, string profile)
            => Vortice.D3DCompiler.Compiler.Compile(Hlsl + "\n", entry, "Display", profile);

        _vs = _device.CreateVertexShader(Compile("VSMain", "vs_5_0").Span);
        _psNearest = _device.CreatePixelShader(Compile("PSNearest", "ps_5_0").Span);
        _psBicubic = _device.CreatePixelShader(Compile("PSBicubic", "ps_5_0").Span);
        _psCrtAccumulate = _device.CreatePixelShader(Compile("PSCRTAccumulate", "ps_5_0").Span);
        _psCrtComposite = _device.CreatePixelShader(Compile("PSCRTComposite", "ps_5_0").Span);
        _psHighQuality = _device.CreatePixelShader(Compile("PSHighQuality", "ps_5_0").Span);
        _psXbrz = _device.CreatePixelShader(Compile("PSXBRZ", "ps_5_0").Span);

        _pointSampler = _device.CreateSamplerState(new SamplerDescription
        {
            Filter = Filter.MinMagMipPoint,
            AddressU = TextureAddressMode.Clamp,
            AddressV = TextureAddressMode.Clamp,
            AddressW = TextureAddressMode.Clamp,
            ComparisonFunc = ComparisonFunction.Never,
            MinLOD = 0,
            MaxLOD = float.MaxValue,
        });
        _linearSampler = _device.CreateSamplerState(new SamplerDescription
        {
            Filter = Filter.MinMagMipLinear,
            AddressU = TextureAddressMode.Clamp,
            AddressV = TextureAddressMode.Clamp,
            AddressW = TextureAddressMode.Clamp,
            ComparisonFunc = ComparisonFunction.Never,
            MinLOD = 0,
            MaxLOD = float.MaxValue,
        });

        // cbuffer is 16-byte aligned; FilterParams is 64 bytes (4 registers).
        _cbuffer = _device.CreateBuffer(new BufferDescription
        {
            ByteWidth = 64,
            Usage = ResourceUsage.Dynamic,
            BindFlags = BindFlags.ConstantBuffer,
            CPUAccessFlags = CpuAccessFlags.Write,
        });
    }

    /// <summary>Recreate the back buffer after the panel resizes.</summary>
    public void Resize(int width, int height)
    {
        width = Math.Max(1, width);
        height = Math.Max(1, height);
        if (width == _width && height == _height) return;
        _width = width;
        _height = height;

        _rtv.Dispose();
        _swapChain.ResizeBuffers(2, (uint)_width, (uint)_height, Format.B8G8R8A8_UNorm, SwapChainFlags.None);
        CreateRenderTarget();
    }

    private void WriteParams(float texW, float texH, float outW, float outH,
                             bool scanline, bool is400, bool persist)
    {
        var p = new FilterParams
        {
            TexW = texW, TexH = texH, OutW = outW, OutH = outH,
            Scanline = scanline ? 1u : 0u,
            Is400 = is400 ? 1u : 0u,
            HqOffset = HqOffset, HqGradient = HqGradient, HqMaxBlend = HqMaxBlend, HqPadding = 0,
            PersistR = persist ? PersistR : 0, PersistG = persist ? PersistG : 0,
            PersistB = persist ? PersistB : 0, PersistPad = 0,
        };
        var map = _ctx.Map(_cbuffer, 0, MapMode.WriteDiscard);
        try { *(FilterParams*)map.DataPointer = p; }
        finally { _ctx.Unmap(_cbuffer, 0); }
    }

    private void Upload(ID3D11Texture2D tex, byte* src, int height)
    {
        int srcRowBytes = _srcWidth * 4;
        var map = _ctx.Map(tex, 0, MapMode.WriteDiscard);
        try
        {
            byte* dst = (byte*)map.DataPointer;
            for (int y = 0; y < height; y++)
                Buffer.MemoryCopy(src + y * srcRowBytes, dst + y * map.RowPitch, srcRowBytes, srcRowBytes);
        }
        finally { _ctx.Unmap(tex, 0); }
    }

    /// <summary>Upload the RGBA frame, run the active filter, and present it.</summary>
    public void Present(ReadOnlySpan<byte> rgba, bool is400Line)
    {
        _lastIs400Line = is400Line;
        bool useFilter = _filter != ScreenFilter.None;

        // AI upscale always consumes the full 640×400 frame (even in 200-line
        // mode), matching macOS — submit it for asynchronous inference.
        if (_filter == ScreenFilter.Ai)
            _ai?.Submit(rgba, _srcWidth, _srcHeight);

        fixed (byte* src = rgba)
        {
            Upload(_srcTex400, src, _srcHeight);

            // In 200-line mode, extract even rows → 640×200 content texture so
            // filters operate at real resolution (matches macOS uploadPixelBuffer).
            // AI doesn't use the 200-line content texture (it upscales 640×400).
            if (!is400Line && useFilter && _filter != ScreenFilter.Ai)
            {
                int rowBytes = _srcWidth * 4;
                fixed (byte* dst = _src200)
                    for (int y = 0; y < Content200Height; y++)
                        Buffer.MemoryCopy(src + y * 2 * rowBytes, dst + y * rowBytes, rowBytes, rowBytes);
                fixed (byte* s2 = _src200)
                    Upload(_srcTex200, s2, Content200Height);
            }
        }

        // Source = 640×200 content for any filter in 200-line mode, else 640×400.
        bool use200 = useFilter && !is400Line;
        var srcSrv = use200 ? _srv200 : _srv400;
        int texH = use200 ? Content200Height : _srcHeight;

        var (vx, vy, vw, vh) = LetterboxViewport();

        _ctx.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
        _ctx.VSSetShader(_vs);

        switch (_filter)
        {
            case ScreenFilter.Crt:
                RenderCrt(srcSrv, texH, vx, vy, vw, vh);
                break;
            case ScreenFilter.Enhanced when use200:
                RenderEnhanced(srcSrv, vx, vy, vw, vh);
                break;
            case ScreenFilter.Ai:
                RenderAi(vx, vy, vw, vh);
                break;
            default:
                RenderSinglePass(srcSrv, texH, vx, vy, vw, vh);
                break;
        }

        _swapChain.Present(1, PresentFlags.None);
    }

    // Bind the constant buffer to both stages (scanlineMultiplier is in the VS-
    // shared cbuffer slot b0; only the PS reads it, but binding to PS is enough).
    private void SetCb() => _ctx.PSSetConstantBuffer(0, _cbuffer);

    private void RenderSinglePass(ID3D11ShaderResourceView srv, int texH,
                                  float vx, float vy, float vw, float vh)
    {
        ID3D11PixelShader ps = _filter switch
        {
            ScreenFilter.Bicubic => _psBicubic,
            ScreenFilter.Xbrz => _psXbrz,
            ScreenFilter.Enhanced => _psXbrz,   // 400-line Enhanced = xBRZ (no HQ pass)
            _ => _psNearest,                    // None, Linear
        };
        bool scanline = _scanlineEnabled && FilterSupportsScanlines(_filter);
        WriteParams(_srcWidth, texH, vw, vh, scanline, texH > 300, false);

        _ctx.OMSetRenderTargets(_rtv);
        _ctx.ClearRenderTargetView(_rtv, new Color4(0f, 0f, 0f, 1f));
        _ctx.RSSetViewport(new Viewport(vx, vy, vw, vh, 0f, 1f));
        _ctx.PSSetShader(ps);
        _ctx.PSSetShaderResource(0, srv);
        _ctx.PSSetSampler(0, _filter == ScreenFilter.Linear ? _linearSampler : _pointSampler);
        SetCb();
        _ctx.Draw(3, 0);
    }

    // Enhanced (200-line): pass 1 HQ de-dithering → 640×200 intermediate, pass 2 xBRZ → screen.
    private void RenderEnhanced(ID3D11ShaderResourceView srv, float vx, float vy, float vw, float vh)
    {
        // Pass 1: HQ → intermediate (full 640×200 viewport, no letterbox).
        WriteParams(_srcWidth, Content200Height, vw, vh, false, false, false);
        _ctx.OMSetRenderTargets(_intermediateRtv);
        _ctx.ClearRenderTargetView(_intermediateRtv, new Color4(0f, 0f, 0f, 1f));
        _ctx.RSSetViewport(new Viewport(0, 0, _srcWidth, Content200Height, 0f, 1f));
        _ctx.PSSetShader(_psHighQuality);
        _ctx.PSSetShaderResource(0, srv);
        _ctx.PSSetSampler(0, _pointSampler);
        SetCb();
        _ctx.Draw(3, 0);

        // Pass 2: xBRZ over the intermediate → screen.
        WriteParams(_srcWidth, Content200Height, vw, vh, false, false, false);
        _ctx.OMSetRenderTargets(_rtv);
        _ctx.ClearRenderTargetView(_rtv, new Color4(0f, 0f, 0f, 1f));
        _ctx.RSSetViewport(new Viewport(vx, vy, vw, vh, 0f, 1f));
        _ctx.PSSetShader(_psXbrz);
        _ctx.PSSetShaderResource(0, _intermediateSrv);
        _ctx.PSSetSampler(0, _pointSampler);
        SetCb();
        _ctx.Draw(3, 0);
    }

    // CRT: pass 1 accumulate (current + decayed previous) → persist ping-pong,
    // pass 2 composite (vignette) → screen. Mirrors EmulatorMetalView's 2-pass.
    private void RenderCrt(ID3D11ShaderResourceView srv, int texH,
                           float vx, float vy, float vw, float vh)
    {
        var prevSrv = _persistFlip ? _persistBSrv : _persistASrv;
        var targetRtv = _persistFlip ? _persistARtv : _persistBRtv;
        var targetSrv = _persistFlip ? _persistASrv : _persistBSrv;

        // First CRT frame after switching in: clear history so no ghost bleeds in.
        if (!_persistPrimed)
        {
            _ctx.ClearRenderTargetView(_persistARtv, new Color4(0f, 0f, 0f, 1f));
            _ctx.ClearRenderTargetView(_persistBRtv, new Color4(0f, 0f, 0f, 1f));
            _persistPrimed = true;
        }

        // Pass 1: accumulate → offscreen 640×400 (full viewport, no letterbox).
        WriteParams(_srcWidth, texH, vw, vh, false, texH > 300, true);
        _ctx.OMSetRenderTargets(targetRtv);
        _ctx.RSSetViewport(new Viewport(0, 0, _srcWidth, _srcHeight, 0f, 1f));
        _ctx.PSSetShader(_psCrtAccumulate);
        _ctx.PSSetShaderResource(0, srv);
        _ctx.PSSetShaderResource(1, prevSrv);
        _ctx.PSSetSampler(0, _pointSampler);
        SetCb();
        _ctx.Draw(3, 0);

        // Pass 2: composite vignette → screen (letterboxed).
        _ctx.OMSetRenderTargets(_rtv);
        _ctx.ClearRenderTargetView(_rtv, new Color4(0f, 0f, 0f, 1f));
        _ctx.RSSetViewport(new Viewport(vx, vy, vw, vh, 0f, 1f));
        _ctx.PSSetShader(_psCrtComposite);
        _ctx.PSSetShaderResource(0, targetSrv);
        _ctx.PSSetSampler(0, _linearSampler);
        SetCb();
        _ctx.Draw(3, 0);

        _recentPersistSrv = targetSrv;   // most recent on-screen accumulation
        _persistFlip = !_persistFlip;
    }

    // AI upscale: show the latest 1280×800 inference output (passthrough, point
    // sampled, letterboxed). Until the first frame lands — or if the model /
    // DirectML is unavailable — fall back to Bicubic on the raw 640×400 frame,
    // matching the macOS selectActiveSource fallback. No scanlines.
    private void RenderAi(float vx, float vy, float vw, float vh)
    {
        // Upload a freshly completed inference into the AI texture (UI thread).
        if (_ai is not null && _ai.TryGetLatest(out var rgba, out int ow, out int oh, out long version)
            && (!_aiHasUpload || version != _aiUploadedVersion))
        {
            EnsureAiTexture(ow, oh);
            fixed (byte* p = rgba)
            {
                int rowBytes = ow * 4;
                var map = _ctx.Map(_aiTex!, 0, MapMode.WriteDiscard);
                try
                {
                    byte* dst = (byte*)map.DataPointer;
                    for (int y = 0; y < oh; y++)
                        Buffer.MemoryCopy(p + y * rowBytes, dst + y * map.RowPitch, rowBytes, rowBytes);
                }
                finally { _ctx.Unmap(_aiTex!, 0); }
            }
            _aiUploadedVersion = version;
            _aiHasUpload = true;
        }

        _ctx.OMSetRenderTargets(_rtv);
        _ctx.ClearRenderTargetView(_rtv, new Color4(0f, 0f, 0f, 1f));
        _ctx.RSSetViewport(new Viewport(vx, vy, vw, vh, 0f, 1f));

        if (_aiHasUpload && _aiSrv is not null)
        {
            WriteParams(_aiTex!.Description.Width, _aiTex.Description.Height, vw, vh, false, true, false);
            _ctx.PSSetShader(_psNearest);
            _ctx.PSSetShaderResource(0, _aiSrv);
            _ctx.PSSetSampler(0, _pointSampler);
        }
        else
        {
            // Fallback: Bicubic on the original 640×400 until inference is ready.
            WriteParams(_srcWidth, _srcHeight, vw, vh, false, true, false);
            _ctx.PSSetShader(_psBicubic);
            _ctx.PSSetShaderResource(0, _srv400);
            _ctx.PSSetSampler(0, _pointSampler);
        }
        SetCb();
        _ctx.Draw(3, 0);
    }

    private void EnsureAiTexture(int w, int h)
    {
        if (_aiTex is not null && _aiTex.Description.Width == w && _aiTex.Description.Height == h)
            return;
        _aiSrv?.Dispose();
        _aiTex?.Dispose();
        _aiTex = MakeDynamic(w, h);
        _aiSrv = _device.CreateShaderResourceView(_aiTex);
    }

    /// <summary>
    /// Render the current frame through the active filter into an offscreen
    /// target and read it back as RGBA8. Matches what's on screen (CRT phosphor,
    /// xBRZ, Enhanced, scanlines), mirroring the macOS captureFilteredImage so
    /// screenshots and save-state thumbnails include the filter. Returns null if
    /// resources aren't ready. Call on the UI thread (shares the live textures
    /// with Present, which also runs there).
    /// </summary>
    public byte[]? CaptureFiltered(out int width, out int height)
    {
        // Capture at the on-screen content size (matches macOS, which captures at
        // the drawable size). xBRZ/HQ output depends on this output:texel ratio.
        var (_, _, vw, vh) = LetterboxViewport();
        width = Math.Max(_srcWidth, (int)Math.Round(vw));
        height = Math.Max(_srcHeight, (int)Math.Round(vh));

        ID3D11Texture2D? captureTex = null, staging = null;
        ID3D11RenderTargetView? captureRtv = null;
        try
        {
            captureTex = _device.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)width, Height = (uint)height, MipLevels = 1, ArraySize = 1,
                Format = Format.R8G8B8A8_UNorm, SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Default, BindFlags = BindFlags.RenderTarget,
                CPUAccessFlags = CpuAccessFlags.None,
            });
            captureRtv = _device.CreateRenderTargetView(captureTex);

            _ctx.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
            _ctx.VSSetShader(_vs);

            bool useFilter = _filter != ScreenFilter.None;
            bool use200 = useFilter && !_lastIs400Line;
            var srcSrv = use200 ? _srv200 : _srv400;
            int texH = use200 ? Content200Height : _srcHeight;

            _ctx.ClearRenderTargetView(captureRtv, new Color4(0f, 0f, 0f, 1f));
            _ctx.RSSetViewport(new Viewport(0, 0, width, height, 0f, 1f));

            if (_filter == ScreenFilter.Crt && _recentPersistSrv is not null)
            {
                // Composite the already-accumulated on-screen persistence (incl.
                // afterglow + vignette), exactly like macOS CRT capture.
                _ctx.OMSetRenderTargets(captureRtv);
                _ctx.PSSetShader(_psCrtComposite);
                _ctx.PSSetShaderResource(0, _recentPersistSrv);
                _ctx.PSSetSampler(0, _linearSampler);
                SetCb();
                _ctx.Draw(3, 0);
            }
            else if (_filter == ScreenFilter.Enhanced && use200)
            {
                // Pass 1: HQ → intermediate, pass 2: xBRZ → capture.
                WriteParams(_srcWidth, Content200Height, width, height, false, false, false);
                _ctx.OMSetRenderTargets(_intermediateRtv);
                _ctx.ClearRenderTargetView(_intermediateRtv, new Color4(0f, 0f, 0f, 1f));
                _ctx.RSSetViewport(new Viewport(0, 0, _srcWidth, Content200Height, 0f, 1f));
                _ctx.PSSetShader(_psHighQuality);
                _ctx.PSSetShaderResource(0, srcSrv);
                _ctx.PSSetSampler(0, _pointSampler);
                SetCb();
                _ctx.Draw(3, 0);

                WriteParams(_srcWidth, Content200Height, width, height, false, false, false);
                _ctx.OMSetRenderTargets(captureRtv);
                _ctx.RSSetViewport(new Viewport(0, 0, width, height, 0f, 1f));
                _ctx.PSSetShader(_psXbrz);
                _ctx.PSSetShaderResource(0, _intermediateSrv);
                _ctx.PSSetSampler(0, _pointSampler);
                SetCb();
                _ctx.Draw(3, 0);
            }
            else if (_filter == ScreenFilter.Ai)
            {
                // Latest AI output (passthrough) if available, else Bicubic on the
                // raw 640×400 — exactly what RenderAi shows on screen.
                _ctx.OMSetRenderTargets(captureRtv);
                if (_aiHasUpload && _aiSrv is not null)
                {
                    WriteParams(_aiTex!.Description.Width, _aiTex.Description.Height, width, height, false, true, false);
                    _ctx.PSSetShader(_psNearest);
                    _ctx.PSSetShaderResource(0, _aiSrv);
                }
                else
                {
                    WriteParams(_srcWidth, _srcHeight, width, height, false, true, false);
                    _ctx.PSSetShader(_psBicubic);
                    _ctx.PSSetShaderResource(0, _srv400);
                }
                _ctx.PSSetSampler(0, _pointSampler);
                SetCb();
                _ctx.Draw(3, 0);
            }
            else
            {
                // Single-pass (None/Linear/Bicubic/xBRZ, 400-line Enhanced, or CRT
                // before its first accumulation).
                ID3D11PixelShader ps = _filter switch
                {
                    ScreenFilter.Bicubic => _psBicubic,
                    ScreenFilter.Xbrz or ScreenFilter.Enhanced => _psXbrz,
                    ScreenFilter.Crt => _psNearest,   // no persistence yet → plain
                    _ => _psNearest,
                };
                bool scanline = _scanlineEnabled && FilterSupportsScanlines(_filter);
                WriteParams(_srcWidth, texH, width, height, scanline, texH > 300, false);
                _ctx.OMSetRenderTargets(captureRtv);
                _ctx.PSSetShader(ps);
                _ctx.PSSetShaderResource(0, srcSrv);
                _ctx.PSSetSampler(0, _filter == ScreenFilter.Linear ? _linearSampler : _pointSampler);
                SetCb();
                _ctx.Draw(3, 0);
            }

            // Read back via a staging copy.
            staging = _device.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)width, Height = (uint)height, MipLevels = 1, ArraySize = 1,
                Format = Format.R8G8B8A8_UNorm, SampleDescription = new SampleDescription(1, 0),
                Usage = ResourceUsage.Staging, BindFlags = BindFlags.None,
                CPUAccessFlags = CpuAccessFlags.Read,
            });
            _ctx.CopyResource(staging, captureTex);

            var result = new byte[width * height * 4];
            int rowBytes = width * 4;
            var map = _ctx.Map(staging, 0, MapMode.Read);
            try
            {
                byte* srcBase = (byte*)map.DataPointer;
                fixed (byte* dst = result)
                    for (int y = 0; y < height; y++)
                        Buffer.MemoryCopy(srcBase + y * map.RowPitch, dst + y * rowBytes, rowBytes, rowBytes);
            }
            finally { _ctx.Unmap(staging, 0); }

            // The render-loop's next Present rebinds everything, so no explicit
            // state restore is needed here.
            return result;
        }
        catch { return null; }
        finally
        {
            captureRtv?.Dispose();
            staging?.Dispose();
            captureTex?.Dispose();
        }
    }

    public static bool FilterSupportsScanlines(ScreenFilter f)
        => f is ScreenFilter.None or ScreenFilter.Linear or ScreenFilter.Bicubic;

    private (float x, float y, float w, float h) LetterboxViewport()
    {
        // Always use the 640×400 display aspect, even when filtering a 640×200
        // content texture (matches macOS — output aspect is fixed at 16:10).
        float targetAspect = (float)_srcWidth / _srcHeight;
        float panelAspect = (float)_width / _height;
        if (panelAspect > targetAspect)
        {
            float w = _height * targetAspect;
            return ((_width - w) * 0.5f, 0f, w, _height);
        }
        else
        {
            float h = _width / targetAspect;
            return (0f, (_height - h) * 0.5f, _width, h);
        }
    }

    public void Dispose()
    {
        _ai?.Dispose();
        _aiSrv?.Dispose();
        _aiTex?.Dispose();
        _cbuffer?.Dispose();
        _pointSampler?.Dispose();
        _linearSampler?.Dispose();
        _psXbrz?.Dispose();
        _psHighQuality?.Dispose();
        _psCrtComposite?.Dispose();
        _psCrtAccumulate?.Dispose();
        _psBicubic?.Dispose();
        _psNearest?.Dispose();
        _vs?.Dispose();
        _persistASrv?.Dispose(); _persistBSrv?.Dispose();
        _persistARtv?.Dispose(); _persistBRtv?.Dispose();
        _persistA?.Dispose(); _persistB?.Dispose();
        _intermediateSrv?.Dispose();
        _intermediateRtv?.Dispose();
        _intermediate?.Dispose();
        _srv200?.Dispose(); _srcTex200?.Dispose();
        _srv400?.Dispose(); _srcTex400?.Dispose();
        _rtv?.Dispose();
        _swapChain?.Dispose();
        _ctx?.Dispose();
        _device?.Dispose();
    }
}
