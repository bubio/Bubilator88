using System;
using System.Threading.Tasks;

namespace Bubilator88.Windows.Ocr;

/// <summary>
/// Dependency-free pixel preprocessing for the OCR pipeline, ported from
/// macOS TranslationManager's scale2x/invertAndSharpen. PC-8801 text is only
/// ~8px tall in the 640x400 framebuffer, so OCR needs the image upscaled
/// (call Scale2x twice for a 4x scale, matching macOS) and contrast-boosted
/// (invert + unsharp mask) before recognition. Row-parallelized via
/// Parallel.For, mirroring macOS's DispatchQueue.concurrentPerform.
/// </summary>
internal static class ImagePreprocessor
{
    /// <summary>
    /// EPX/Scale2x edge-aware 2x upscale. Call twice for a 4x scale.
    /// </summary>
    public static byte[] Scale2x(byte[] rgba, int width, int height, out int outWidth, out int outHeight)
    {
        // Local copies: `out` parameters can't be captured inside the
        // Parallel.For lambda below (CS1628).
        int dstWidth = width * 2;
        int dstHeight = height * 2;
        var dst = new byte[dstWidth * dstHeight * 4];

        Parallel.For(0, height, y =>
        {
            for (int x = 0; x < width; x++)
            {
                int p = ReadPixel(rgba, width, height, x, y);
                int a = ReadPixel(rgba, width, height, x, y - 1);
                int b = ReadPixel(rgba, width, height, x + 1, y);
                int c = ReadPixel(rgba, width, height, x - 1, y);
                int d = ReadPixel(rgba, width, height, x, y + 1);

                int p1 = (c == a && c != d && a != b) ? a : p;
                int p2 = (a == b && a != c && b != d) ? b : p;
                int p3 = (d == c && d != b && c != a) ? c : p;
                int p4 = (b == d && b != a && d != c) ? d : p;

                WritePixel(dst, dstWidth, x * 2, y * 2, p1);
                WritePixel(dst, dstWidth, x * 2 + 1, y * 2, p2);
                WritePixel(dst, dstWidth, x * 2, y * 2 + 1, p3);
                WritePixel(dst, dstWidth, x * 2 + 1, y * 2 + 1, p4);
            }
        });

        outWidth = dstWidth;
        outHeight = dstHeight;
        return dst;
    }

    /// <summary>
    /// Invert RGB (alpha untouched) then apply a 3x3 unsharp mask, in place.
    /// PC-88 games often render light-on-dark text; Vision/OcrEngine are both
    /// tuned for dark-on-light, so inverting first improves recognition.
    /// </summary>
    public static void InvertAndSharpen(byte[] rgba, int width, int height, float sharpenAmount = 0.5f)
    {
        Parallel.For(0, height, y =>
        {
            int rowStart = y * width * 4;
            for (int x = 0; x < width; x++)
            {
                int i = rowStart + x * 4;
                rgba[i] = (byte)(255 - rgba[i]);
                rgba[i + 1] = (byte)(255 - rgba[i + 1]);
                rgba[i + 2] = (byte)(255 - rgba[i + 2]);
            }
        });

        byte[] src = (byte[])rgba.Clone();
        Parallel.For(0, height, y =>
        {
            for (int x = 0; x < width; x++)
            {
                for (int ch = 0; ch < 3; ch++)
                {
                    float blur = 0f;
                    for (int dy = -1; dy <= 1; dy++)
                    {
                        for (int dx = -1; dx <= 1; dx++)
                        {
                            int sx = Math.Clamp(x + dx, 0, width - 1);
                            int sy = Math.Clamp(y + dy, 0, height - 1);
                            blur += src[(sy * width + sx) * 4 + ch];
                        }
                    }
                    blur /= 9f;

                    float center = src[(y * width + x) * 4 + ch];
                    float sharpened = center + sharpenAmount * (center - blur);
                    rgba[(y * width + x) * 4 + ch] = ClampByte(sharpened);
                }
            }
        });
    }

    /// <summary>Swap R/B channels: SoftwareBitmap requires Bgra8, but
    /// b88_render_rgba writes R,G,B,A order.</summary>
    public static byte[] RgbaToBgra(byte[] rgba)
    {
        var bgra = new byte[rgba.Length];
        Parallel.For(0, rgba.Length / 4, i =>
        {
            int o = i * 4;
            bgra[o] = rgba[o + 2];
            bgra[o + 1] = rgba[o + 1];
            bgra[o + 2] = rgba[o];
            bgra[o + 3] = rgba[o + 3];
        });
        return bgra;
    }

    private static int ReadPixel(byte[] rgba, int width, int height, int x, int y)
    {
        x = Math.Clamp(x, 0, width - 1);
        y = Math.Clamp(y, 0, height - 1);
        int i = (y * width + x) * 4;
        return rgba[i] | (rgba[i + 1] << 8) | (rgba[i + 2] << 16) | (rgba[i + 3] << 24);
    }

    private static void WritePixel(byte[] dst, int width, int x, int y, int packed)
    {
        int i = (y * width + x) * 4;
        dst[i] = (byte)packed;
        dst[i + 1] = (byte)(packed >> 8);
        dst[i + 2] = (byte)(packed >> 16);
        dst[i + 3] = (byte)(packed >> 24);
    }

    private static byte ClampByte(float v) => (byte)Math.Clamp(v, 0f, 255f);
}
