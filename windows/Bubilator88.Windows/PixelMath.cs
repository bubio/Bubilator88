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
}
