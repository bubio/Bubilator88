using System;
using System.Collections.Generic;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Bubilator88.Windows;

/// <summary>
/// The Settings dialog — a faithful (form-level) port of the macOS Settings
/// window (Bubilator88/Views/SettingsView.swift). macOS opens it from the
/// application-menu Preferences item; Windows has no such menu, so it opens from
/// the Emulator menu instead.
///
/// <para>The macOS window has five tabs (General / Display / Audio / Keyboard /
/// Controller), but most of those settings drive features the Windows native
/// host doesn't implement yet (controller, mouse, immersive audio, translation,
/// recording, …). This dialog therefore mirrors the tab layout but
/// surfaces only the preferences that have a working Windows backend. Each
/// control applies live and persists to settings.json immediately, matching the
/// macOS bindings (there is no OK/Cancel — just Close).</para>
/// </summary>
public sealed partial class MainWindow
{
    /// <summary>Push the keyboard layout + numpad-emulation prefs into the static
    /// <see cref="KeyMapping"/> resolver. Called at startup and on every change.</summary>
    private void ApplyKeyboardConfig()
    {
        KeyMapping.Layout = _keyboardLayout switch
        {
            "jis" => KeyMapping.KbLayout.Jis,
            "us" => KeyMapping.KbLayout.Us,
            _ => KeyMapping.KbLayout.Auto,
        };
        KeyMapping.ArrowKeysAsNumpad = _arrowKeysAsNumpad;
        KeyMapping.NumberRowAsNumpad = _numberRowAsNumpad;
        KeyMapping.WasdAsNumpad = _wasdAsNumpad;
    }

    /// <summary>Pixel-perfect letterboxing applies only in fullscreen (the windowed
    /// view scales are already exact integer multiples of 640×400).</summary>
    private void ApplyIntegerScaling() => _screen?.SetIntegerScaling(_fullscreen && _fullscreenIntegerScaling);

    private async void OnSettings(object sender, RoutedEventArgs e)
    {
        var pivot = new Pivot { Width = 440 };
        pivot.Items.Add(new PivotItem { Header = "General", Content = WrapTab(BuildGeneralTab()) });
        pivot.Items.Add(new PivotItem { Header = "Display", Content = WrapTab(BuildDisplayTab()) });
        pivot.Items.Add(new PivotItem { Header = "Audio", Content = WrapTab(BuildAudioTab()) });
        pivot.Items.Add(new PivotItem { Header = "Keyboard", Content = WrapTab(BuildKeyboardTab()) });

        var dialog = new ContentDialog
        {
            Title = "Settings",
            Content = pivot,
            CloseButtonText = "Close",
            XamlRoot = Root.XamlRoot,
        };
        await ShowDialogAsync(dialog);
    }

    // MARK: - Tab builders

    private FrameworkElement BuildGeneralTab()
    {
        var panel = NewTabPanel();
        panel.Children.Add(Section("Screenshot",
            LabeledCombo("Format",
                new[] { ("PNG", "png"), ("JPEG", "jpeg"), ("HEIC", "heic") },
                _screenshotFormat,
                tag => { _screenshotFormat = tag; SaveSettings(); }),
            "Image format used when saving screenshots."));
        return panel;
    }

    private FrameworkElement BuildDisplayTab()
    {
        var panel = NewTabPanel();

        var caption = Caption(FullscreenScalingCaption());
        var fit = new RadioButton { Content = "Fit to Screen", GroupName = "Scaling", IsChecked = !_fullscreenIntegerScaling };
        var integer = new RadioButton { Content = "Integer Scaling", GroupName = "Scaling", IsChecked = _fullscreenIntegerScaling };
        fit.Checked += (_, _) => { _fullscreenIntegerScaling = false; ApplyIntegerScaling(); SaveSettings(); caption.Text = FullscreenScalingCaption(); };
        integer.Checked += (_, _) => { _fullscreenIntegerScaling = true; ApplyIntegerScaling(); SaveSettings(); caption.Text = FullscreenScalingCaption(); };

        panel.Children.Add(Section("Fullscreen", new[] { (FrameworkElement)fit, integer, caption }));
        return panel;
    }

    private FrameworkElement BuildAudioTab()
    {
        var panel = NewTabPanel();

        var value = new TextBlock
        {
            Text = $"{_audioBufferMs} ms",
            VerticalAlignment = VerticalAlignment.Center,
            MinWidth = 52,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"),
        };
        var slider = new Slider
        {
            Minimum = 20, Maximum = 500, StepFrequency = 20,
            Value = _audioBufferMs, Width = 260,
        };
        slider.ValueChanged += (_, ev) =>
        {
            _audioBufferMs = (int)ev.NewValue;
            if (_host is not null) _host.AudioBufferMs = _audioBufferMs;
            value.Text = $"{_audioBufferMs} ms";
            SaveSettings();
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        row.Children.Add(value);
        row.Children.Add(slider);

        panel.Children.Add(Section("Audio Buffer", new[] { (FrameworkElement)row },
            "Lower values reduce latency but may cause crackling."));

        var fddToggle = Toggle("Enable FDD Sound", _fddSoundEnabled, isOn =>
        {
            _fddSoundEnabled = isOn;
            if (isOn)
            {
                _fddSound?.Start(_fddSoundDeviceId);
            }
            else
            {
                _fddSound?.Stop();
            }
            SaveSettings();
        });
        var fddVolume = LabeledCombo("Volume",
            new[] { ("Low", "0"), ("Medium", "1"), ("High", "2") },
            _fddSoundVolumeLevel.ToString(),
            tag =>
            {
                _fddSoundVolumeLevel = int.Parse(tag);
                if (_fddSound is not null) _fddSound.Volume = FddSound.VolumeForLevel(_fddSoundVolumeLevel);
                SaveSettings();
            });

        // Output-device picker — mirrors macOS's SettingsView "Output Device"
        // Picker (fddDeviceBinding), which lets FDD sound target a different
        // physical device than the main YM2608 audio. Populated live each time
        // the Settings dialog opens, matching the macOS `.task` device refresh.
        var devices = AudioDeviceList.OutputDevices();
        var fddDevice = LabeledCombo("Output Device",
            devices.ConvertAll(d => (d.Name, d.Id)).ToArray(),
            _fddSoundDeviceId,
            deviceId =>
            {
                _fddSoundDeviceId = deviceId;
                _fddSound?.ApplyOutputDevice(deviceId);
                SaveSettings();
            });

        panel.Children.Add(Section("FDD Sound", new FrameworkElement[] { fddToggle, fddVolume, fddDevice },
            "Synthesized floppy disk seek and read sounds with stereo drive separation."));

        return panel;
    }

    private FrameworkElement BuildKeyboardTab()
    {
        var panel = NewTabPanel();

        var detected = Caption(DetectedLayoutCaption());
        var layoutCombo = LabeledCombo("Keyboard Layout",
            new[] { ("Auto-detect", "auto"), ("JIS", "jis"), ("US (ANSI)", "us") },
            _keyboardLayout,
            tag => { _keyboardLayout = tag; ApplyKeyboardConfig(); SaveSettings(); detected.Text = DetectedLayoutCaption(); });
        panel.Children.Add(Section("Layout", new[] { (FrameworkElement)layoutCombo, detected }));

        var arrows = NumpadToggle("Arrow Keys as Numpad",
            "Maps arrow keys to numpad 8/2/4/6 for game character movement.",
            _arrowKeysAsNumpad, v => { _arrowKeysAsNumpad = v; ApplyKeyboardConfig(); SaveSettings(); });
        var numbers = NumpadToggle("Number Row as Numpad",
            "Maps number row 0-9 to numpad 0-9 (e.g. adventure-game menu selections).",
            _numberRowAsNumpad, v => { _numberRowAsNumpad = v; ApplyKeyboardConfig(); SaveSettings(); });
        var wasd = NumpadToggle("WASD as Numpad",
            "Maps WASD to numpad 8/4/2/6 for left-hand character movement.",
            _wasdAsNumpad, v => { _wasdAsNumpad = v; ApplyKeyboardConfig(); SaveSettings(); });

        panel.Children.Add(Section("Numpad Emulation", new[] { arrows, numbers, wasd }));
        return panel;
    }

    // MARK: - Dynamic caption text

    private string FullscreenScalingCaption()
        => _fullscreenIntegerScaling
            ? "Pixel-perfect display with black borders. No scaling artifacts."
            : "Fill the screen as much as possible while maintaining aspect ratio.";

    private static string DetectedLayoutCaption()
        => $"Detected: {(KeyMapping.EffectiveLayout() == KeyMapping.KbLayout.Jis ? "JIS" : "US (ANSI)")}";

    // MARK: - UI helpers

    private static ScrollViewer WrapTab(FrameworkElement content)
        => new()
        {
            Content = content,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
            MaxHeight = 420,
            Padding = new Thickness(2, 8, 12, 8),
        };

    private static StackPanel NewTabPanel()
        => new() { Spacing = 18, Margin = new Thickness(0, 4, 0, 4) };

    private static StackPanel Section(string title, IEnumerable<FrameworkElement> children, string? caption = null)
    {
        var panel = new StackPanel { Spacing = 6 };
        panel.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold });
        foreach (var c in children) panel.Children.Add(c);
        if (caption is not null) panel.Children.Add(Caption(caption));
        return panel;
    }

    private static StackPanel Section(string title, FrameworkElement child, string? caption = null)
        => Section(title, new[] { child }, caption);

    private static TextBlock Caption(string text)
        => new() { Text = text, Opacity = 0.6, FontSize = 12, TextWrapping = TextWrapping.Wrap };

    /// A "Label  [ ComboBox ]" row whose options are (display, tag) pairs; invokes
    /// <paramref name="onPick"/> with the chosen tag.
    private static Grid LabeledCombo(string label, (string Text, string Tag)[] options,
                                     string current, Action<string> onPick)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var text = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(text, 0);

        var combo = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        int selected = 0;
        for (int i = 0; i < options.Length; i++)
        {
            combo.Items.Add(new ComboBoxItem { Content = options[i].Text, Tag = options[i].Tag });
            if (options[i].Tag == current) selected = i;
        }
        combo.SelectedIndex = selected;
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedItem is ComboBoxItem item && item.Tag is string tag) onPick(tag);
        };
        Grid.SetColumn(combo, 1);

        grid.Children.Add(text);
        grid.Children.Add(combo);
        return grid;
    }

    /// A checkbox bound to an on/off callback — the shared building block
    /// behind both <see cref="NumpadToggle"/> and standalone toggles like the
    /// Audio tab's "Enable FDD Sound" checkbox.
    private static CheckBox Toggle(string label, bool isOn, Action<bool> onToggle)
    {
        var check = new CheckBox { Content = label, IsChecked = isOn };
        check.Checked += (_, _) => onToggle(true);
        check.Unchecked += (_, _) => onToggle(false);
        return check;
    }

    /// A checkbox + caption pair for the numpad-emulation toggles.
    private static StackPanel NumpadToggle(string label, string caption, bool isOn, Action<bool> onToggle)
    {
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(Toggle(label, isOn, onToggle));
        panel.Children.Add(Caption(caption));
        return panel;
    }
}
