using Bubilator88.Windows;
using Xunit;

namespace Bubilator88.Windows.Tests;

public class PixelMathTests
{
    [Theory]
    [InlineData(0f, 0)]        // exact low end
    [InlineData(1f, 255)]      // exact high end
    [InlineData(0.5f, 128)]    // 0.5*255 + 0.5 = 128.0 → 128 (round to nearest)
    [InlineData(0.392156862f, 100)] // 100/255 round-trips back to 100
    public void ClampToByte_InRange_RoundsToNearest(float input, byte expected)
        => Assert.Equal(expected, PixelMath.ClampToByte(input));

    [Theory]
    [InlineData(-0.0001f)]
    [InlineData(-1f)]
    [InlineData(-100f)]
    public void ClampToByte_BelowZero_ClampsToZero(float input)
        => Assert.Equal(0, PixelMath.ClampToByte(input));

    [Theory]
    [InlineData(1.0001f)]
    [InlineData(2f)]
    [InlineData(100f)]
    public void ClampToByte_AboveOne_ClampsTo255(float input)
        => Assert.Equal(255, PixelMath.ClampToByte(input));
}
