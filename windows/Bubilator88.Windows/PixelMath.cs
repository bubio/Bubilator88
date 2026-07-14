using System;

namespace Bubilator88.Windows;

/// <summary>
/// Small, dependency-free pixel arithmetic helpers, factored out so they can be
/// unit-tested in isolation (the call sites live in classes that pull in heavy
/// native dependencies such as ONNX Runtime / D3D).
/// </summary>
internal static class PixelMath
{
    /// <summary>
    /// Convert a normalized float sample in [0,1] to an 8-bit channel value,
    /// rounding to nearest and clamping out-of-range inputs. Mirrors the macOS
    /// AIUpscaler conversion <c>min(255, max(0, Int(v*255 + 0.5)))</c> exactly —
    /// model outputs occasionally overshoot [0,1], so the clamp is load-bearing.
    /// </summary>
    public static byte ClampToByte(float v)
    {
        int n = (int)(v * 255f + 0.5f);
        if (n < 0) n = 0; else if (n > 255) n = 255;
        return (byte)n;
    }

    /// <summary>
    /// Aspect-fit (letterboxed) content rectangle for a <paramref name="srcWidth"/>x
    /// <paramref name="srcHeight"/> image inside a <paramref name="panelWidth"/>x
    /// <paramref name="panelHeight"/> panel. Shared by D3DScreen (device-pixel space,
    /// for the render viewport) and the OCR overlay (DIP space, for positioning
    /// detection boxes) so the two never drift out of sync — the fit fractions
    /// are scale-invariant, so the same formula works in either unit.
    /// </summary>
    public static (float x, float y, float w, float h) ContentRect(
        float panelWidth, float panelHeight, float srcWidth, float srcHeight, bool integerScaling)
    {
        if (integerScaling)
        {
            int scale = (int)Math.Min(panelWidth / srcWidth, panelHeight / srcHeight);
            if (scale >= 1)
            {
                float iw = srcWidth * scale;
                float ih = srcHeight * scale;
                return ((panelWidth - iw) * 0.5f, (panelHeight - ih) * 0.5f, iw, ih);
            }
        }

        float targetAspect = srcWidth / srcHeight;
        float panelAspect = panelWidth / panelHeight;
        if (panelAspect > targetAspect)
        {
            float w = panelHeight * targetAspect;
            return ((panelWidth - w) * 0.5f, 0f, w, panelHeight);
        }
        else
        {
            float h = panelWidth / targetAspect;
            return (0f, (panelHeight - h) * 0.5f, panelWidth, h);
        }
    }
}
