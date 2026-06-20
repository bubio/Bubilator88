using System;
using System.Diagnostics;
using System.IO;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Bubilator88.Windows;

public sealed partial class MainWindow : Window
{
    private const double FrameSeconds = 1.0 / 60.0;
    private const int MaxCatchUpFrames = 4;

    private EmulatorHost? _host;
    private D3DScreen? _screen;
    private XAudioSink? _audio;

    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private double _accumulator;
    private bool _running;

    public MainWindow()
    {
        InitializeComponent();
        Root.Loaded += OnLoaded;
        Closed += OnClosed;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _host = new EmulatorHost();
            _host.LoadRoms();
            ApplyBootConfig();

            _screen = new D3DScreen(ScreenPanel, EmulatorHost.ScreenWidth, EmulatorHost.ScreenHeight);
            _audio = new XAudioSink();

            _running = true;
            CompositionTarget.Rendering += OnRendering;
            Root.Focus(FocusState.Programmatic);
            StatusText.Text = "Ready (no disk → BASIC)";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Init failed: {ex.Message}";
        }
    }

    private (int dipSw1, int dipSw2Base) BootSelection() => BootModeCombo.SelectedIndex switch
    {
        1 => (NativeApi.DipSw1_N88, NativeApi.DipSw2_V1H),
        2 => (NativeApi.DipSw1_N88, NativeApi.DipSw2_V1S),
        3 => (NativeApi.DipSw1_NBasic, NativeApi.DipSw2_V2),
        _ => (NativeApi.DipSw1_N88, NativeApi.DipSw2_V2),
    };

    private void ApplyBootConfig()
    {
        if (_host is null) return;
        var (dipSw1, dipSw2Base) = BootSelection();
        _host.Configure(ClockToggle.IsOn, dipSw1, dipSw2Base);
    }

    private void OnRendering(object? sender, object e)
    {
        if (!_running || _host is null || _screen is null) return;

        double now = _clock.Elapsed.TotalSeconds;
        _accumulator += now - _lastTick;
        _lastTick = now;

        int frames = 0;
        while (_accumulator >= FrameSeconds && frames < MaxCatchUpFrames)
        {
            _host.RunFrameAndRender(blinkCursor: true);
            if (_audio is not null) _host.DrainAudio(_audio);
            _accumulator -= FrameSeconds;
            frames++;
        }
        // Drop backlog if we fell too far behind (avoid spiral of death).
        if (_accumulator > FrameSeconds * MaxCatchUpFrames)
            _accumulator = 0;

        if (frames > 0)
            _screen.Present(_host.Pixels);
    }

    private double _lastTick;

    private void OnPanelSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_screen is null) return;
        int w = (int)(ScreenPanel.ActualWidth * ScreenPanel.CompositionScaleX);
        int h = (int)(ScreenPanel.ActualHeight * ScreenPanel.CompositionScaleY);
        _screen.Resize(w, h);
    }

    private async void OnMountDisk(object sender, RoutedEventArgs e)
    {
        if (_host is null) return;

        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".d88");
        picker.FileTypeFilter.Add(".d77");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));

        StorageFile? file = await picker.PickSingleFileAsync();
        if (file is null) return;

        byte[] bytes = await File.ReadAllBytesAsync(file.Path);
        int images = _host.MountDisk(0, bytes);
        // Re-apply boot config so the strap sees the disk and boots FDD.
        ApplyBootConfig();
        StatusText.Text = images > 0
            ? $"{file.Name} ({images} image{(images == 1 ? "" : "s")})"
            : $"Failed to parse {file.Name}";
    }

    private void OnReset(object sender, RoutedEventArgs e) => ApplyBootConfig();

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        _host?.KeyDown(e.Key);
        e.Handled = true;
    }

    private void OnKeyUp(object sender, KeyRoutedEventArgs e)
    {
        _host?.KeyUp(e.Key);
        e.Handled = true;
    }

    private void OnClosed(object sender, WindowEventArgs e)
    {
        _running = false;
        CompositionTarget.Rendering -= OnRendering;
        _audio?.Dispose();
        _screen?.Dispose();
        _host?.Dispose();
    }
}
