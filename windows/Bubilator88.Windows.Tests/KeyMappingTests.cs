using System;
using Bubilator88.Windows;
using Windows.System;
using Xunit;

namespace Bubilator88.Windows.Tests;

/// <summary>
/// Unit tests for the Windows VirtualKey → PC-8801 matrix resolver.
///
/// <para>KeyMapping holds process-wide mutable configuration (layout + the three
/// numpad-emulation toggles). xUnit constructs a fresh test-class instance per
/// test, so the constructor here pins that static state to a deterministic
/// baseline (explicit US layout, no numpad emulation) and Dispose restores it,
/// keeping the tests independent and order-insensitive. Tests never rely on the
/// Auto layout, which would call GetKeyboardType on the host.</para>
/// </summary>
public sealed class KeyMappingTests : IDisposable
{
    public KeyMappingTests()
    {
        KeyMapping.Layout = KeyMapping.KbLayout.Us;
        KeyMapping.ArrowKeysAsNumpad = false;
        KeyMapping.NumberRowAsNumpad = false;
        KeyMapping.WasdAsNumpad = false;
    }

    public void Dispose()
    {
        KeyMapping.Layout = KeyMapping.KbLayout.Auto;
        KeyMapping.ArrowKeysAsNumpad = false;
        KeyMapping.NumberRowAsNumpad = false;
        KeyMapping.WasdAsNumpad = false;
    }

    // OEM virtual-key codes that aren't named in the VirtualKey enum.
    private const VirtualKey VkOemPlus = (VirtualKey)0xBB;   // US '=' / JIS ';'
    private const VirtualKey VkOem7 = (VirtualKey)0xDE;      // US '\'' / JIS '^'
    private const VirtualKey VkOemMinus = (VirtualKey)0xBD;  // '-'
    private const VirtualKey VkOem102 = (VirtualKey)0xE2;    // JIS '\_' (unmapped on US)

    [Theory]
    // Letters
    [InlineData(VirtualKey.A, 2, 1)]
    [InlineData(VirtualKey.Z, 5, 2)]
    // Number row
    [InlineData(VirtualKey.Number0, 6, 0)]
    [InlineData(VirtualKey.Number9, 7, 1)]
    // Editing / control
    [InlineData(VirtualKey.Enter, 1, 7)]
    [InlineData(VirtualKey.Space, 9, 6)]
    [InlineData(VirtualKey.Escape, 9, 7)]
    // Arrows (base, no numpad emulation)
    [InlineData(VirtualKey.Up, 8, 1)]
    [InlineData(VirtualKey.Left, 0x0A, 2)]
    // OEM symbol (US-ANSI base)
    [InlineData(VkOemMinus, 5, 7)]
    public void TryMap_UsBaseLayout_ResolvesToExpectedMatrix(VirtualKey key, int row, int bit)
    {
        Assert.True(KeyMapping.TryMap(key, out var matrix));
        Assert.Equal(new KeyMapping.MatrixKey(row, bit), matrix);
    }

    [Fact]
    public void TryMap_UnmappedKey_ReturnsFalse()
    {
        // Sleep has no PC-8801 equivalent and is absent from every table.
        Assert.False(KeyMapping.TryMap(VirtualKey.Sleep, out _));
    }

    [Fact]
    public void TryMap_Oem102_OnUsLayout_IsUnmapped()
    {
        // VK_OEM_102 ('\_') exists only on a JIS keyboard; the US base map omits it.
        Assert.False(KeyMapping.TryMap(VkOem102, out _));
    }

    [Theory]
    // Keys whose JIS keycap differs from US-ANSI map to a different PC-88 symbol.
    [InlineData(VkOemPlus, 7, 3)]  // JIS ';' → semicolon (US '=' → caret 5,6)
    [InlineData(VkOem7, 5, 6)]     // JIS '^' → caret     (US '\'' → colon 7,2)
    [InlineData(VkOem102, 7, 7)]   // JIS '\_' → underscore (unmapped on US)
    public void TryMap_JisLayout_AppliesJisOverrides(VirtualKey key, int row, int bit)
    {
        KeyMapping.Layout = KeyMapping.KbLayout.Jis;
        Assert.True(KeyMapping.TryMap(key, out var matrix));
        Assert.Equal(new KeyMapping.MatrixKey(row, bit), matrix);
    }

    [Theory]
    // The same OEM keys resolve to the US base targets when the layout is US.
    [InlineData(VkOemPlus, 5, 6)]  // US '=' → caret
    [InlineData(VkOem7, 7, 2)]     // US '\'' → colon
    public void TryMap_UsLayout_DoesNotApplyJisOverrides(VirtualKey key, int row, int bit)
    {
        Assert.True(KeyMapping.TryMap(key, out var matrix));
        Assert.Equal(new KeyMapping.MatrixKey(row, bit), matrix);
    }

    [Fact]
    public void TryMap_ArrowKeysAsNumpad_RemapsArrowsToNumpadCluster()
    {
        KeyMapping.ArrowKeysAsNumpad = true;
        Assert.True(KeyMapping.TryMap(VirtualKey.Up, out var matrix));
        Assert.Equal(new KeyMapping.MatrixKey(1, 0), matrix); // ↑ → kp8, not base (8,1)
    }

    [Fact]
    public void TryMap_NumberRowAsNumpad_RemapsNumberRow()
    {
        KeyMapping.NumberRowAsNumpad = true;
        Assert.True(KeyMapping.TryMap(VirtualKey.Number2, out var matrix));
        Assert.Equal(new KeyMapping.MatrixKey(0, 2), matrix); // 2 → kp2, not base (6,2)
    }

    [Fact]
    public void TryMap_WasdAsNumpad_RemapsWasd()
    {
        KeyMapping.WasdAsNumpad = true;
        Assert.True(KeyMapping.TryMap(VirtualKey.A, out var matrix));
        Assert.Equal(new KeyMapping.MatrixKey(0, 4), matrix); // A → kp4, not base (2,1)
    }

    [Fact]
    public void TryMap_NumpadEmulation_TakesPrecedenceOverJisOverrides()
    {
        // Resolution order is numpad → JIS → base, so WASD emulation wins over the
        // JIS layout even for a key the JIS table also touches conceptually.
        KeyMapping.Layout = KeyMapping.KbLayout.Jis;
        KeyMapping.WasdAsNumpad = true;
        Assert.True(KeyMapping.TryMap(VirtualKey.W, out var matrix));
        Assert.Equal(new KeyMapping.MatrixKey(1, 0), matrix); // W → kp8
    }

    [Fact]
    public void TryMap_NumpadEmulationDisabled_FallsThroughToBase()
    {
        // With the toggle off, WASD letters resolve to their normal letter matrix.
        Assert.True(KeyMapping.TryMap(VirtualKey.W, out var matrix));
        Assert.Equal(new KeyMapping.MatrixKey(4, 7), matrix);
    }
}
