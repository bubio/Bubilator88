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
using Windows.System;
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

    // Per-drive mounted-disk state (bytes kept so images can be switched without
    // re-reading the file; mirrors macOS MountedDiskInfo for multi-image .d88).
    private sealed class DriveSlot
    {
        public byte[]? Bytes;
        public string FileName = "";       // display base name (no extension)
        public string[] ImageNames = Array.Empty<string>();
        public int ImageCount;
        public int CurrentImage;
        public bool Occupied => Bytes != null;
    }
    private readonly DriveSlot[] _drives = { new(), new() };

    // Status-bar state.
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
            RebuildDriveMenu(0);
            RebuildDriveMenu(1);
            UpdateDiskStatus();

            // Auto-mount a disk passed on the command line (Explorer "Open with",
            // drag-drop onto the exe, or `Bubilator88.Windows.exe game.d88`).
            string? diskArg = FindDiskArgument();
            if (diskArg is not null)
                MountPath(0, diskArg);
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
            LevelMeter.Width = 56.0 * Math.Clamp(_host.LastPeak, 0f, 1f);
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
        MountBytes(drive, file.Name, bytes);
    }

    private static string? FindDiskArgument()
    {
        foreach (string a in Environment.GetCommandLineArgs())
        {
            string ext = System.IO.Path.GetExtension(a).ToLowerInvariant();
            if ((ext == ".d88" || ext == ".d77") && File.Exists(a))
                return a;
        }
        return null;
    }

    private void MountPath(int drive, string path)
    {
        try { MountBytes(drive, System.IO.Path.GetFileName(path), File.ReadAllBytes(path)); }
        catch (Exception ex) { StatusText.Text = $"Mount failed: {ex.Message}"; }
    }

    private void MountBytes(int drive, string name, byte[] bytes)
    {
        if (_host is null) return;

        // Parse once to learn the image count + names, then mount image 0.
        int images = _host.ProbeDisk(bytes, out string[] rawNames);
        if (images <= 0)
        {
            StatusText.Text = $"Failed to parse {name}";
            return;
        }

        string fileBase = System.IO.Path.GetFileNameWithoutExtension(name);
        var slot = _drives[drive];
        slot.Bytes = bytes;
        slot.FileName = fileBase;
        slot.ImageCount = images;
        slot.ImageNames = ResolveImageNames(rawNames, fileBase, images);
        slot.CurrentImage = 0;

        _host.MountDisk(drive, bytes, 0);
        // Mounting drive 0 flips the boot strap (DIP SW2 bit 3) — reboot so the
        // FDD boot path kicks in. Drive 1 doesn't affect the strap.
        if (drive == 0) ApplyBootConfig();

        RebuildDriveMenu(drive);
        UpdateDiskStatus();
    }

    /// <summary>
    /// Switch to a different image within the same mounted .d88 — a floppy swap,
    /// NOT a reboot (matches macOS switchDiskImage). The machine keeps running.
    /// </summary>
    private void SwitchImage(int drive, int index)
    {
        var slot = _drives[drive];
        if (_host is null || !slot.Occupied || index < 0 || index >= slot.ImageCount) return;
        if (index == slot.CurrentImage) return;

        _host.MountDisk(drive, slot.Bytes!, index);
        slot.CurrentImage = index;
        RebuildDriveMenu(drive);
        UpdateDiskStatus();
    }

    private void OnEjectDrive0(object sender, RoutedEventArgs e) => EjectDrive(0);
    private void OnEjectDrive1(object sender, RoutedEventArgs e) => EjectDrive(1);

    private void EjectDrive(int drive)
    {
        _host?.EjectDisk(drive);
        _drives[drive] = new DriveSlot();
        RebuildDriveMenu(drive);
        UpdateDiskStatus();
    }

    /// Resolve embedded image names, falling back to "<file> #<i>" for unnamed
    /// images (and bare "<file>" for a single-image disk). Mirrors macOS
    /// makeDirectDiskInfo.
    private static string[] ResolveImageNames(string[] raw, string fileBase, int count)
    {
        var result = new string[count];
        for (int i = 0; i < count; i++)
        {
            string n = i < raw.Length ? raw[i].Trim() : "";
            result[i] = n.Length > 0 ? n : (count > 1 ? $"{fileBase} #{i}" : fileBase);
        }
        return result;
    }

    /// Rebuild a drive's submenu: Mount… / Eject, plus a radio list of images
    /// when the mounted .d88 holds more than one.
    private void RebuildDriveMenu(int drive)
    {
        var sub = drive == 0 ? Drive0Sub : Drive1Sub;
        sub.Items.Clear();

        var mount = new MenuFlyoutItem { Text = "Mount…" };
        mount.Click += drive == 0 ? OnMountDrive0 : OnMountDrive1;
        mount.KeyboardAccelerators.Add(new KeyboardAccelerator
        {
            Modifiers = VirtualKeyModifiers.Control,
            Key = drive == 0 ? VirtualKey.Number1 : VirtualKey.Number2,
        });
        sub.Items.Add(mount);

        var slot = _drives[drive];
        var eject = new MenuFlyoutItem { Text = "Eject", IsEnabled = slot.Occupied };
        eject.Click += drive == 0 ? OnEjectDrive0 : OnEjectDrive1;
        sub.Items.Add(eject);

        if (slot.Occupied && slot.ImageCount > 1)
        {
            sub.Items.Add(new MenuFlyoutSeparator());
            for (int i = 0; i < slot.ImageCount; i++)
            {
                int index = i;
                var item = new RadioMenuFlyoutItem
                {
                    Text = $"{i + 1}. {slot.ImageNames[i]}",
                    GroupName = $"Drive{drive}Images",
                    IsChecked = i == slot.CurrentImage,
                };
                item.Click += (_, _) => SwitchImage(drive, index);
                sub.Items.Add(item);
            }
        }
    }

    private void UpdateDiskStatus()
    {
        var parts = new List<string>();
        for (int d = 0; d < 2; d++)
        {
            var slot = _drives[d];
            if (!slot.Occupied) continue;
            string label = slot.ImageCount > 1
                ? $"{slot.ImageNames[slot.CurrentImage]} ({slot.CurrentImage + 1}/{slot.ImageCount})"
                : slot.FileName;
            parts.Add($"D{d + 1}: {label}");
        }
        StatusText.Text = parts.Count == 0 ? "No disk (→ BASIC)" : string.Join("    ", parts);
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
