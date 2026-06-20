using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Graphics;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.UI;
using WinRT.Interop;

namespace Bubilator88.Windows;

public sealed partial class MainWindow : Window
{
    private const double FrameSeconds = 1.0 / 60.0;
    private const int MaxCatchUpFrames = 4;
    // Render ticks a disk LED stays lit after an access pulse (~200 ms @ 60 Hz).
    private const int LedHoldTicks = 12;
    // Approx. non-screen chrome (menu + status + title) in DIPs, for window sizing.
    private const double ChromeHeightDip = 96.0;

    private EmulatorHost? _host;
    private D3DScreen? _screen;
    private XAudioSink? _audio;

    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private double _accumulator;
    private double _lastTick;
    private bool _running;
    private bool _paused;
    private bool _fullscreen;

    // Boot configuration (mirrors the former combo/toggle state).
    private int _bootModeIndex;
    private bool _clock8MHz = true;

    // Status-bar state.
    private string? _disk0Name;
    private string? _disk1Name;
    private int _drive0Led;
    private int _drive1Led;
    private int _fpsFrames;
    private double _fpsAccum;

    private readonly SolidColorBrush _ledOn = new(Microsoft.UI.Colors.LimeGreen);
    private readonly SolidColorBrush _ledOff = new(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF));

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
            _lastTick = _clock.Elapsed.TotalSeconds;
            CompositionTarget.Rendering += OnRendering;
            Root.Focus(FocusState.Programmatic);
            UpdateDiskStatus();
        }
        catch (Exception ex)
        {
            // Tear down anything that was constructed before the failure so the
            // native handle / D3D / XAudio resources don't leak.
            _running = false;
            CompositionTarget.Rendering -= OnRendering;
            _audio?.Dispose();
            _screen?.Dispose();
            _host?.Dispose();
            _audio = null;
            _screen = null;
            _host = null;
            StatusText.Text = $"Init failed: {ex.Message}";
        }
    }

    // MARK: - Boot configuration

    private (int dipSw1, int dipSw2Base) BootSelection() => _bootModeIndex switch
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
        _host.Configure(_clock8MHz, dipSw1, dipSw2Base);
        ModeLabel.Text = _bootModeIndex switch
        {
            1 => "N88-V1H",
            2 => "N88-V1S",
            3 => "N-BASIC",
            _ => "N88-V2",
        };
        ClockLabel.Text = _clock8MHz ? "8MHz" : "4MHz";
    }

    // MARK: - Frame loop

    private void OnRendering(object? sender, object e)
    {
        if (!_running || _host is null || _screen is null) return;

        double now = _clock.Elapsed.TotalSeconds;
        double dt = now - _lastTick;
        _lastTick = now;

        if (_paused)
        {
            _accumulator = 0;
            return;
        }

        _accumulator += dt;

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
        {
            _screen.Present(_host.Pixels);
            SampleAndDecayLeds();
            _fpsFrames += frames;
        }
        UpdateFps(dt);
    }

    private void SampleAndDecayLeds()
    {
        _host!.SampleDiskAccess(out bool d0, out bool d1);
        if (d0) _drive0Led = LedHoldTicks;
        if (d1) _drive1Led = LedHoldTicks;
        UpdateLed(Drive0Led, ref _drive0Led);
        UpdateLed(Drive1Led, ref _drive1Led);
    }

    private void UpdateLed(Ellipse led, ref int counter)
    {
        Brush target = counter > 0 ? _ledOn : _ledOff;
        if (counter > 0) counter--;
        if (!ReferenceEquals(led.Fill, target)) led.Fill = target;
    }

    private void UpdateFps(double dt)
    {
        _fpsAccum += dt;
        if (_fpsAccum < 0.5) return;
        double fps = _fpsFrames / _fpsAccum;
        FpsLabel.Text = $"{fps:0} fps";
        _fpsFrames = 0;
        _fpsAccum = 0;
    }

    // MARK: - Emulator menu

    private void OnPauseResume(object sender, RoutedEventArgs e)
    {
        if (_host is null) return;
        _paused = !_paused;
        PauseResumeItem.Text = _paused ? "Resume" : "Pause";
        RunStateLabel.Text = _paused ? "Paused" : "Running";
    }

    private void OnReset(object sender, RoutedEventArgs e) => ApplyBootConfig();

    private void OnBootMode(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement fe && int.TryParse(fe.Tag?.ToString(), out int idx))
        {
            _bootModeIndex = idx;
            ApplyBootConfig();
        }
    }

    private void OnClock(object sender, RoutedEventArgs e)
    {
        if (_host is null) return;
        if (sender is FrameworkElement fe && int.TryParse(fe.Tag?.ToString(), out int mhz))
        {
            // CPU clock is a live timing change — no reset needed.
            _clock8MHz = mhz == 8;
            _host.SetClock(_clock8MHz);
            ClockLabel.Text = _clock8MHz ? "8MHz" : "4MHz";
        }
    }

    // MARK: - Disk menu

    private async void OnMountDrive0(object sender, RoutedEventArgs e) => await MountDriveAsync(0);
    private async void OnMountDrive1(object sender, RoutedEventArgs e) => await MountDriveAsync(1);

    private async Task MountDriveAsync(int drive)
    {
        if (_host is null) return;

        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".d88");
        picker.FileTypeFilter.Add(".d77");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));

        StorageFile? file = await picker.PickSingleFileAsync();
        if (file is null) return;

        byte[] bytes = await File.ReadAllBytesAsync(file.Path);
        int images = _host.MountDisk(drive, bytes);
        if (images <= 0)
        {
            StatusText.Text = $"Failed to parse {file.Name}";
            return;
        }

        if (drive == 0) _disk0Name = file.Name; else _disk1Name = file.Name;
        // Mounting drive 0 flips the boot strap (DIP SW2 bit 3) — reboot so the
        // FDD boot path kicks in. Drive 1 doesn't affect the strap.
        if (drive == 0) ApplyBootConfig();
        UpdateDiskStatus();
    }

    private void OnEjectDrive0(object sender, RoutedEventArgs e)
    {
        _host?.EjectDisk(0);
        _disk0Name = null;
        UpdateDiskStatus();
    }

    private void OnEjectDrive1(object sender, RoutedEventArgs e)
    {
        _host?.EjectDisk(1);
        _disk1Name = null;
        UpdateDiskStatus();
    }

    private void UpdateDiskStatus()
    {
        if (_disk0Name is null && _disk1Name is null)
        {
            StatusText.Text = "No disk (→ BASIC)";
            return;
        }
        var parts = new List<string>();
        if (_disk0Name is not null) parts.Add($"D1: {_disk0Name}");
        if (_disk1Name is not null) parts.Add($"D2: {_disk1Name}");
        StatusText.Text = string.Join("    ", parts);
    }

    // MARK: - View menu

    private void OnWindowScale(object sender, RoutedEventArgs e)
    {
        if (_fullscreen) return;
        if (sender is FrameworkElement fe && int.TryParse(fe.Tag?.ToString(), out int scale))
        {
            double rs = Root.XamlRoot?.RasterizationScale ?? 1.0;
            int w = (int)(EmulatorHost.ScreenWidth * scale * rs);
            int h = (int)((EmulatorHost.ScreenHeight * scale + ChromeHeightDip) * rs);
            AppWindow.Resize(new SizeInt32(w, h));
        }
    }

    private void OnToggleFullscreen(object sender, RoutedEventArgs e)
    {
        _fullscreen = !_fullscreen;
        AppWindow.SetPresenter(_fullscreen
            ? AppWindowPresenterKind.FullScreen
            : AppWindowPresenterKind.Default);
        FullscreenItem.IsChecked = _fullscreen;
    }

    // MARK: - Help menu

    private async void OnAbout(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            Title = "Bubilator88",
            Content = "NEC PC-8801-FA behavioral emulator\n" +
                      "Windows native shell (C# + WinUI 3)\n\n" +
                      "Emulation core: Swift (Bubilator88C.dll)",
            CloseButtonText = "OK",
            XamlRoot = Root.XamlRoot,
        };
        await dialog.ShowAsync();
    }

    // MARK: - Input & lifetime

    private void OnPanelSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_screen is null) return;
        int w = (int)(ScreenPanel.ActualWidth * ScreenPanel.CompositionScaleX);
        int h = (int)(ScreenPanel.ActualHeight * ScreenPanel.CompositionScaleY);
        _screen.Resize(w, h);
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // Only swallow keys the emulator actually consumes, so system
        // accelerators (Alt+F4 etc.) and unmapped keys keep working.
        if (_host?.KeyDown(e.Key) == true)
            e.Handled = true;
    }

    private void OnKeyUp(object sender, KeyRoutedEventArgs e)
    {
        if (_host?.KeyUp(e.Key) == true)
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
