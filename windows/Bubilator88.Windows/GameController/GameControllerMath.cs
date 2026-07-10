namespace Bubilator88.Windows.GameController;

/// <summary>
/// Pure hysteresis math for analog stick/trigger → digital button conversion,
/// split out from <see cref="GameControllerManager"/> so it has no dependency
/// on EmulatorHost or Windows.Gaming.Input and can be unit-tested standalone
/// (mirrors macOS GameControllerManager.handleAnalogStick's asymmetric
/// deadzone/release-threshold approach, which avoids jitter at the boundary).
/// </summary>
internal static class GameControllerMath
{
    internal const double StickDeadzone = 0.3;
    internal const double StickReleaseThreshold = 0.2;
    internal const double TriggerPressThreshold = 0.5;
    internal const double TriggerReleaseThreshold = 0.4;

    /// <summary>Press at <see cref="StickDeadzone"/>, release at the lower
    /// <see cref="StickReleaseThreshold"/>.</summary>
    internal static bool StickAxisActive(bool wasActive, double magnitude)
        => wasActive ? magnitude >= StickReleaseThreshold : magnitude >= StickDeadzone;

    /// <summary>Press at <see cref="TriggerPressThreshold"/>, release at the lower
    /// <see cref="TriggerReleaseThreshold"/>.</summary>
    internal static bool TriggerActive(bool wasPressed, double value)
        => wasPressed ? value >= TriggerReleaseThreshold : value >= TriggerPressThreshold;
}
