using System;
using System.Collections.Generic;
using Bubilator88.Windows;
using Windows.Gaming.Input;

namespace Bubilator88.Windows.GameController;

/// <summary>
/// Polls a single active Windows.Gaming.Input.Gamepad and translates button/
/// stick state into PC-8801 keyboard-matrix presses or host commands, per
/// <see cref="ControllerButtonMapping"/>.
///
/// Unlike macOS's GCController (delegate-callback based), Gamepad has no
/// per-button pressed-changed event, so this polls <see cref="Poll"/> once
/// per frame-loop tick and diffs against the previous reading to synthesize
/// press/release edges. Connect/disconnect is likewise detected by
/// re-enumerating <see cref="Gamepad.Gamepads"/> each poll rather than
/// subscribing to GamepadAdded/GamepadRemoved (which fire off the UI thread).
/// </summary>
internal sealed class GameControllerManager
{
    private Gamepad? _active;
    private GamepadButtons _prevButtons = GamepadButtons.None;
    private bool _prevLeftTrigger;
    private bool _prevRightTrigger;
    private bool _stickUp, _stickDown, _stickLeft, _stickRight;
    private readonly HashSet<MappedKey> _pressedKeys = new();

    public bool Enabled { get; set; }

    public ControllerButtonMapping Mapping { get; set; } = ControllerButtonMapping.Defaults;

    /// <summary>Invoked (press-edge only) when a button resolves to a HostCommand.</summary>
    public Action<HostCommand>? OnHostCommand { get; set; }

    public int ConnectedCount => Gamepad.Gamepads.Count;

    /// <summary>Call once per frame-loop tick, regardless of pause state, so
    /// held buttons and pause/resume keep working while paused.</summary>
    public void Poll(EmulatorHost host)
    {
        if (!Enabled)
        {
            if (_active is not null) ReleaseAll(host);
            return;
        }

        var pads = Gamepad.Gamepads;
        if (_active is null || !Contains(pads, _active))
        {
            if (_active is not null) ReleaseAll(host);
            _active = pads.Count > 0 ? pads[0] : null;
            if (_active is null) return;
        }

        GamepadReading reading;
        try
        {
            reading = _active.GetCurrentReading();
        }
        catch
        {
            // Pad vanished between the enumeration check and the read.
            ReleaseAll(host);
            return;
        }

        DiffButtons(host, reading.Buttons);
        DiffTrigger(host, ref _prevLeftTrigger, reading.LeftTrigger, ControllerButton.LeftTrigger);
        DiffTrigger(host, ref _prevRightTrigger, reading.RightTrigger, ControllerButton.RightTrigger);
        HandleAnalogStick(host, reading.LeftThumbstickX, reading.LeftThumbstickY);
    }

    private static bool Contains(IReadOnlyList<Gamepad> pads, Gamepad pad)
    {
        for (int i = 0; i < pads.Count; i++)
            if (ReferenceEquals(pads[i], pad)) return true;
        return false;
    }

    private void DiffButtons(EmulatorHost host, GamepadButtons current)
    {
        DiffButton(host, current, GamepadButtons.DPadUp, ControllerButton.DpadUp);
        DiffButton(host, current, GamepadButtons.DPadDown, ControllerButton.DpadDown);
        DiffButton(host, current, GamepadButtons.DPadLeft, ControllerButton.DpadLeft);
        DiffButton(host, current, GamepadButtons.DPadRight, ControllerButton.DpadRight);
        DiffButton(host, current, GamepadButtons.A, ControllerButton.A);
        DiffButton(host, current, GamepadButtons.B, ControllerButton.B);
        DiffButton(host, current, GamepadButtons.X, ControllerButton.X);
        DiffButton(host, current, GamepadButtons.Y, ControllerButton.Y);
        DiffButton(host, current, GamepadButtons.LeftShoulder, ControllerButton.LeftShoulder);
        DiffButton(host, current, GamepadButtons.RightShoulder, ControllerButton.RightShoulder);
        DiffButton(host, current, GamepadButtons.Menu, ControllerButton.Start);
        DiffButton(host, current, GamepadButtons.View, ControllerButton.Select);
        DiffButton(host, current, GamepadButtons.LeftThumbstick, ControllerButton.LeftStickButton);
        DiffButton(host, current, GamepadButtons.RightThumbstick, ControllerButton.RightStickButton);
        _prevButtons = current;
    }

    private void DiffButton(EmulatorHost host, GamepadButtons current, GamepadButtons flag, ControllerButton button)
    {
        bool was = (_prevButtons & flag) != 0;
        bool now = (current & flag) != 0;
        if (was == now) return;
        HandleButton(host, Mapping.Action(button), now);
    }

    private void DiffTrigger(EmulatorHost host, ref bool wasPressed, double value, ControllerButton button)
    {
        bool now = GameControllerMath.TriggerActive(wasPressed, value);
        if (now == wasPressed) return;
        wasPressed = now;
        HandleButton(host, Mapping.Action(button), now);
    }

    /// <summary>Hysteresis-based analog→digital conversion (press at
    /// StickDeadzone, release at the lower StickReleaseThreshold, asymmetric
    /// to avoid jitter at the boundary) — mirrors macOS's handleAnalogStick.</summary>
    private void HandleAnalogStick(EmulatorHost host, double x, double y)
    {
        _stickUp = UpdateAxis(host, _stickUp, y, positive: true, ControllerButton.DpadUp);
        _stickDown = UpdateAxis(host, _stickDown, y, positive: false, ControllerButton.DpadDown);
        _stickLeft = UpdateAxis(host, _stickLeft, x, positive: false, ControllerButton.DpadLeft);
        _stickRight = UpdateAxis(host, _stickRight, x, positive: true, ControllerButton.DpadRight);
    }

    private bool UpdateAxis(EmulatorHost host, bool wasActive, double value, bool positive, ControllerButton button)
    {
        double magnitude = positive ? value : -value;
        bool now = GameControllerMath.StickAxisActive(wasActive, magnitude);
        if (now == wasActive) return wasActive;
        HandleButton(host, Mapping.Action(button), now);
        return now;
    }

    private void HandleButton(EmulatorHost host, ButtonAction action, bool pressed)
    {
        switch (action.Kind)
        {
            case ButtonActionKind.Pc88Key:
                var key = action.Key;
                if (key.IsNone) return;
                if (pressed)
                {
                    host.PressMatrixKey(key.Row, key.Bit);
                    _pressedKeys.Add(key);
                }
                else
                {
                    host.ReleaseMatrixKey(key.Row, key.Bit);
                    _pressedKeys.Remove(key);
                }
                break;

            case ButtonActionKind.HostCommand:
                if (pressed) OnHostCommand?.Invoke(action.Command);
                break;
        }
    }

    /// <summary>Release every currently-held PC-88 key and reset edge-detection
    /// state. Call on disconnect, disable, mapping change, and app shutdown —
    /// avoids stuck keys, mirroring macOS's releaseAllKeys().</summary>
    public void ReleaseAll(EmulatorHost host)
    {
        foreach (var key in _pressedKeys)
            host.ReleaseMatrixKey(key.Row, key.Bit);
        _pressedKeys.Clear();

        _prevButtons = GamepadButtons.None;
        _prevLeftTrigger = false;
        _prevRightTrigger = false;
        _stickUp = _stickDown = _stickLeft = _stickRight = false;
        _active = null;
    }
}
