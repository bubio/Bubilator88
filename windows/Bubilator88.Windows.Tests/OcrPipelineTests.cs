using Bubilator88.Windows;
using Bubilator88.Windows.Ocr;
using Xunit;

namespace Bubilator88.Windows.Tests;

/// <summary>
/// Unit tests for the pure, WinRT-free parts of the OCR overlay pipeline:
/// Japanese-script detection, katakana normalization (OcrTypes.cs), the
/// Scale2x/invert-sharpen/RGBA-to-BGRA pixel algorithms (ImagePreprocessor.cs),
/// and the shared letterbox math (PixelMath.ContentRect, also used by
/// D3DScreen). OcrManager itself (Windows.Media.Ocr, background pipeline) is
/// not linked here — it needs a live OcrEngine/language pack and is exercised
/// manually (see the implementation plan's verification steps).
/// </summary>
public sealed class OcrPipelineTests
{
    [Theory]
    [InlineData("こんにちは", true)]  // Hiragana
    [InlineData("カタカナ", true)]    // Katakana
    [InlineData("漢字", true)]        // CJK Unified Ideographs
    [InlineData("ｶﾀｶﾅ", true)]        // Half-width Katakana
    [InlineData("、", true)]          // CJK Symbols and Punctuation
    [InlineData("Hello123", false)]   // Pure ASCII
    [InlineData("", false)]
    public void ContainsJapanese_DetectsEachUnicodeRange(string text, bool expected)
        => Assert.Equal(expected, OcrTypes.ContainsJapanese(text));

    [Fact]
    public void KatakanaToHiragana_ConvertsFullwidthKatakana()
        => Assert.Equal("かたかな", OcrTypes.KatakanaToHiragana("カタカナ"));

    [Fact]
    public void KatakanaToHiragana_ConvertsHalfwidthKatakana()
        => Assert.Equal("かたかな", OcrTypes.KatakanaToHiragana("ｶﾀｶﾅ"));

    [Fact]
    public void KatakanaToHiragana_ConvertsHalfwidthVoicedKatakana()
        => Assert.Equal("が", OcrTypes.KatakanaToHiragana("ｶﾞ")); // half-width カ + dakuten -> ガ -> が

    [Fact]
    public void Scale2x_DoublesDimensions_AndPreservesFlatColor()
    {
        // 2x2 flat-color source: every Scale2x edge-detection branch degrades
        // to the center pixel when all neighbors are equal, so the output
        // must be the exact same flat color at 2x the dimensions.
        byte[] src = { 10, 20, 30, 255, 10, 20, 30, 255, 10, 20, 30, 255, 10, 20, 30, 255 };

        byte[] dst = ImagePreprocessor.Scale2x(src, 2, 2, out int w, out int h);

        Assert.Equal(4, w);
        Assert.Equal(4, h);
        Assert.Equal(w * h * 4, dst.Length);
        for (int i = 0; i < dst.Length; i += 4)
        {
            Assert.Equal(10, dst[i]);
            Assert.Equal(20, dst[i + 1]);
            Assert.Equal(30, dst[i + 2]);
            Assert.Equal(255, dst[i + 3]);
        }
    }

    [Fact]
    public void InvertAndSharpen_InvertsRgbButNotAlpha()
    {
        // Flat color: every 3x3 neighborhood (after edge-clamping) equals the
        // center pixel, so the unsharp step is a no-op and only the invert
        // should be observable.
        byte[] rgba = { 10, 20, 30, 128, 10, 20, 30, 128, 10, 20, 30, 128, 10, 20, 30, 128 };

        ImagePreprocessor.InvertAndSharpen(rgba, 2, 2);

        for (int i = 0; i < rgba.Length; i += 4)
        {
            Assert.Equal(245, rgba[i]);
            Assert.Equal(235, rgba[i + 1]);
            Assert.Equal(225, rgba[i + 2]);
            Assert.Equal(128, rgba[i + 3]); // alpha untouched
        }
    }

    [Fact]
    public void RgbaToBgra_SwapsRedAndBlueChannels()
    {
        byte[] rgba = { 10, 20, 30, 40 };

        byte[] bgra = ImagePreprocessor.RgbaToBgra(rgba);

        Assert.Equal(new byte[] { 30, 20, 10, 40 }, bgra);
    }

    [Theory]
    [InlineData(2000f, 1000f, 200f, 0f, 1600f, 1000f)]  // wider than 640:400 -> pillarbox
    [InlineData(800f, 1000f, 0f, 250f, 800f, 500f)]     // narrower than 640:400 -> letterbox
    public void ContentRect_NormalAspectFit_CentersLetterbox(
        float panelW, float panelH, float expectedX, float expectedY, float expectedW, float expectedH)
    {
        var (x, y, w, h) = PixelMath.ContentRect(panelW, panelH, 640f, 400f, integerScaling: false);

        AssertClose(expectedX, x);
        AssertClose(expectedY, y);
        AssertClose(expectedW, w);
        AssertClose(expectedH, h);
    }

    [Fact]
    public void ContentRect_IntegerScaling_SnapsToWholeMultiple()
    {
        var (x, y, w, h) = PixelMath.ContentRect(1930f, 1210f, 640f, 400f, integerScaling: true);

        AssertClose(5f, x);
        AssertClose(5f, y);
        AssertClose(1920f, w);
        AssertClose(1200f, h);
    }

    [Fact]
    public void ContentRect_IntegerScaling_FallsBackToAspectFit_WhenPanelSmallerThanNative()
    {
        // Panel smaller than the 640x400 source: scale would be 0, so this
        // must fall through to the normal aspect-fit rather than collapsing
        // the content rect to nothing.
        var (x, y, w, h) = PixelMath.ContentRect(300f, 200f, 640f, 400f, integerScaling: true);

        AssertClose(0f, x);
        AssertClose(6.25f, y);
        AssertClose(300f, w);
        AssertClose(187.5f, h);
    }

    private static void AssertClose(float expected, float actual)
        => Assert.True(System.Math.Abs(expected - actual) < 0.01f, $"expected {expected}, got {actual}");
}
