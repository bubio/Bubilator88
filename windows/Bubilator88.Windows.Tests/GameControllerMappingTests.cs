using System;
using System.Text.Json;
using Bubilator88.Windows.GameController;
using Xunit;

namespace Bubilator88.Windows.Tests;

/// <summary>
/// Unit tests for the pure, host-agnostic parts of Windows game-controller
/// support: default-mapping resolution/serialization (ControllerTypes.cs) and
/// stick/trigger hysteresis (GameControllerMath.cs). The Gamepad-polling and
/// EmulatorHost-driving parts of GameControllerManager aren't linked here —
/// they need a live Gamepad/native DLL and are exercised manually (see the
/// implementation plan's verification steps).
/// </summary>
public sealed class GameControllerMappingTests
{
    [Fact]
    public void Defaults_RoundTripsThroughJson()
    {
        string json = JsonSerializer.Serialize(ControllerButtonMapping.Defaults);
        var restored = JsonSerializer.Deserialize<ControllerButtonMapping>(json);

        Assert.NotNull(restored);
        foreach (ControllerButton button in Enum.GetValues<ControllerButton>())
        {
            Assert.Equal(ControllerButtonMapping.Defaults.Action(button), restored!.Action(button));
        }
    }

    [Theory]
    [InlineData(ControllerButton.A, ButtonActionKind.Pc88Key, 9, 6)]      // Space
    [InlineData(ControllerButton.B, ButtonActionKind.Pc88Key, 9, 7)]      // Escape
    [InlineData(ControllerButton.DpadUp, ButtonActionKind.Pc88Key, 1, 0)] // numpad 8
    public void Defaults_ResolveExpectedPc88Keys(ControllerButton button, ButtonActionKind kind, int row, int bit)
    {
        var action = ControllerButtonMapping.Defaults.Action(button);
        Assert.Equal(kind, action.Kind);
        Assert.Equal(new MappedKey(row, bit), action.Key);
    }

    [Theory]
    [InlineData(ControllerButton.LeftTrigger)]
    [InlineData(ControllerButton.RightTrigger)]
    [InlineData(ControllerButton.Start)]
    [InlineData(ControllerButton.Select)]
    public void Defaults_LeaveTriggersAndStartSelectUnassigned(ControllerButton button)
    {
        Assert.Equal(ButtonAction.None, ControllerButtonMapping.Defaults.Action(button));
    }

    [Fact]
    public void Action_FallsBackToDefault_WhenButtonUnset()
    {
        var mapping = new ControllerButtonMapping(); // empty Buttons dict
        Assert.Equal(ControllerButtonMapping.Defaults.Action(ControllerButton.A), mapping.Action(ControllerButton.A));
    }

    [Fact]
    public void Action_PrefersExplicitOverride_OverDefault()
    {
        var mapping = ControllerButtonMapping.Defaults.Clone();
        mapping.Buttons[ControllerButton.A.ToString()] = ButtonAction.None;
        Assert.Equal(ButtonAction.None, mapping.Action(ControllerButton.A));
        // Defaults singleton must be unaffected by mutating the clone.
        Assert.NotEqual(ButtonAction.None, ControllerButtonMapping.Defaults.Action(ControllerButton.A));
    }

    [Theory]
    // Rising edge: inactive below deadzone, active at/above it.
    [InlineData(false, 0.29, false)]
    [InlineData(false, 0.30, true)]
    [InlineData(false, 0.35, true)]
    // Falling edge: active stays active until it drops below the (lower)
    // release threshold, not the deadzone — this is the hysteresis gap.
    [InlineData(true, 0.25, true)]
    [InlineData(true, 0.20, true)]
    [InlineData(true, 0.19, false)]
    public void StickAxisActive_AppliesAsymmetricHysteresis(bool wasActive, double magnitude, bool expected)
    {
        Assert.Equal(expected, GameControllerMath.StickAxisActive(wasActive, magnitude));
    }

    [Theory]
    [InlineData(false, 0.49, false)]
    [InlineData(false, 0.50, true)]
    [InlineData(true, 0.45, true)]
    [InlineData(true, 0.40, true)]
    [InlineData(true, 0.39, false)]
    public void TriggerActive_AppliesAsymmetricHysteresis(bool wasPressed, double value, bool expected)
    {
        Assert.Equal(expected, GameControllerMath.TriggerActive(wasPressed, value));
    }
}
