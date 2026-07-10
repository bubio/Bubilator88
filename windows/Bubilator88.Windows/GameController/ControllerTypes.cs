using System.Collections.Generic;

namespace Bubilator88.Windows.GameController;

/// <summary>
/// A PC-8801 keyboard matrix cell (row, bit) — the same coordinate space as
/// <see cref="KeyMapping.MatrixKey"/>, duplicated here (rather than reused)
/// so this type stays JSON-serializable as a plain settings POCO without
/// depending on KeyMapping's internal visibility.
/// </summary>
internal readonly record struct MappedKey(int Row, int Bit)
{
    public static readonly MappedKey None = new(-1, -1);
    public bool IsNone => Row < 0;
}

/// <summary>What a controller button press resolves to. Declared public (unlike
/// its sibling types) only so it can be a parameter type on public xUnit
/// [Theory] test methods in the source-linked test project — it isn't
/// otherwise exposed outside this assembly.</summary>
public enum ButtonActionKind { None, Pc88Key, HostCommand }

/// <summary>
/// App-level actions a controller button can invoke directly (Windows has no
/// equivalent of macOS's NSEvent-shortcut-synthesis trick — these map 1:1 to
/// existing MainWindow menu-command methods).
/// </summary>
internal enum HostCommand
{
    PauseResume,
    Reset,
    QuickSave,
    QuickLoad,
    ToggleFullscreen,
    Screenshot,
    CopyScreen,
}

/// <summary>
/// The resolved action for one controller button. A flat (non-tagged-union)
/// shape so it serializes as plain JSON via System.Text.Json with no custom
/// converter, unlike macOS's Codable ButtonAction enum. A record struct for
/// free structural equality (used by mapping-resolution tests).
/// </summary>
internal readonly record struct ButtonAction
{
    public ButtonActionKind Kind { get; init; }
    public MappedKey Key { get; init; }
    public HostCommand Command { get; init; }

    public static readonly ButtonAction None = new() { Kind = ButtonActionKind.None };
    public static ButtonAction Pc88(MappedKey key) => new() { Kind = ButtonActionKind.Pc88Key, Key = key };
    public static ButtonAction Host(HostCommand command) => new() { Kind = ButtonActionKind.HostCommand, Command = command };
}

/// <summary>Mappable controller inputs (mirrors macOS's ControllerButton enum).
/// Declared public for the same [Theory]-parameter reason as ButtonActionKind.</summary>
public enum ControllerButton
{
    DpadUp, DpadDown, DpadLeft, DpadRight,
    A, B, X, Y,
    LeftShoulder, RightShoulder,
    LeftTrigger, RightTrigger,
    Start, Select,
    LeftStickButton, RightStickButton,
}

/// <summary>
/// A full button→action mapping. Windows v1 uses a single global instance
/// (no per-controller-model keying like macOS's productCategory-keyed
/// dictionary — Windows.Gaming.Input.Gamepad exposes no product identity).
/// </summary>
internal sealed class ControllerButtonMapping
{
    public Dictionary<string, ButtonAction> Buttons { get; set; } = new();

    /// <summary>Resolve a button's action, falling back to the default mapping
    /// when unset (mirrors macOS ControllerButtonMapping.action(for:)).</summary>
    public ButtonAction Action(ControllerButton button)
    {
        string key = button.ToString();
        if (Buttons.TryGetValue(key, out var action)) return action;
        if (Defaults.Buttons.TryGetValue(key, out var def)) return def;
        return ButtonAction.None;
    }

    public static ControllerButtonMapping Defaults { get; } = BuildDefaults();

    /// <summary>A deep copy, safe to mutate independently of <see cref="Defaults"/>
    /// (callers must never mutate the shared Defaults instance directly).</summary>
    public ControllerButtonMapping Clone() => new() { Buttons = new Dictionary<string, ButtonAction>(Buttons) };

    private static ControllerButtonMapping BuildDefaults()
    {
        var m = new ControllerButtonMapping();
        void Set(ControllerButton b, ButtonAction a) => m.Buttons[b.ToString()] = a;

        // Dpad → numpad direction cluster (matches KeyMapping.cs's ArrowToNumpad
        // targets: NumberPad8=(1,0), NumberPad2=(0,2), NumberPad4=(0,4), NumberPad6=(0,6)).
        Set(ControllerButton.DpadUp, ButtonAction.Pc88(new MappedKey(1, 0)));
        Set(ControllerButton.DpadDown, ButtonAction.Pc88(new MappedKey(0, 2)));
        Set(ControllerButton.DpadLeft, ButtonAction.Pc88(new MappedKey(0, 4)));
        Set(ControllerButton.DpadRight, ButtonAction.Pc88(new MappedKey(0, 6)));

        // Face buttons — matches macOS defaults (Space/Escape/Return/Z).
        Set(ControllerButton.A, ButtonAction.Pc88(new MappedKey(9, 6)));  // Space
        Set(ControllerButton.B, ButtonAction.Pc88(new MappedKey(9, 7)));  // Escape
        Set(ControllerButton.X, ButtonAction.Pc88(new MappedKey(1, 7)));  // Return
        Set(ControllerButton.Y, ButtonAction.Pc88(new MappedKey(5, 2)));  // Z

        // Shoulders — matches macOS defaults (X key / Shift).
        Set(ControllerButton.LeftShoulder, ButtonAction.Pc88(new MappedKey(5, 0)));   // X
        Set(ControllerButton.RightShoulder, ButtonAction.Pc88(new MappedKey(8, 6)));  // Shift

        // Triggers — macOS's rewind-hold / Shift+Tab defaults have no Windows
        // equivalent (no rewind feature); left unassigned.
        Set(ControllerButton.LeftTrigger, ButtonAction.None);
        Set(ControllerButton.RightTrigger, ButtonAction.None);

        // Start/Select/stick buttons — unassigned, matching macOS (Start is
        // deliberately left unbound so it can't accidentally break a running
        // BASIC program via STOP).
        Set(ControllerButton.Start, ButtonAction.None);
        Set(ControllerButton.Select, ButtonAction.None);
        Set(ControllerButton.LeftStickButton, ButtonAction.None);
        Set(ControllerButton.RightStickButton, ButtonAction.None);

        return m;
    }
}
