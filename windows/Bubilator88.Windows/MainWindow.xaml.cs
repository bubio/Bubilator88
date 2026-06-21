using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
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
    private int _windowScale = 2;   // ×1/×2/×3, persisted

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
        public EmulatorHost.ImageInfo[] Images = Array.Empty<EmulatorHost.ImageInfo>();
        public int ImageCount;
        public int CurrentImage;
        public bool WriteProtected;
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

            // Lock the window to fixed view scales and restore the saved scale.
            ConfigureFixedSize();
            LoadSettings();
            (_windowScale switch { 1 => Scale1, 3 => Scale3, _ => Scale2 }).IsChecked = true;
            ApplyWindowScale(_windowScale, persist: false);

            LoadRecent();
            RebuildDiskMenu();
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
        await MountSingleAsync(drive, file.Name, bytes, file.Path);
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
        try
        {
            byte[] bytes = File.ReadAllBytes(path);
            _ = MountSingleAsync(drive, System.IO.Path.GetFileName(path), bytes, path);
        }
        catch (Exception ex) { StatusText.Text = $"Mount failed: {ex.Message}"; }
    }

    /// Mount a single drive from a .d88 blob. For a multi-image file the user is
    /// first shown an image-selection dialog (matching the macOS .multiImageD88
    /// picker sheet); single-image files mount directly. A non-null sourcePath is
    /// recorded in the recent-files list.
    private async Task MountSingleAsync(int drive, string name, byte[] bytes, string? sourcePath)
    {
        if (_host is null) return;

        int images = _host.ProbeDisk(bytes, out EmulatorHost.ImageInfo[] infos);
        if (images <= 0)
        {
            StatusText.Text = $"Failed to parse {name}";
            return;
        }

        int index = 0;
        if (images > 1)
        {
            index = await PickImageAsync(name, infos);
            if (index < 0) return;   // user cancelled
        }

        FillSlot(_drives[drive], bytes, name, infos, index);
        _host.MountDisk(drive, bytes, index);
        // Mounting drive 0 flips the boot strap (DIP SW2 bit 3) — reboot so the
        // FDD boot path kicks in. Drive 1 doesn't affect the strap.
        if (drive == 0) ApplyBootConfig();

        if (sourcePath is not null) AddRecent(sourcePath);
        RebuildDiskMenu();
        UpdateDiskStatus();
    }

    /// Show the disk-image selection dialog for a multi-image .d88 (mirrors the
    /// macOS picker: a row per image showing index, name, disk type and a lock
    /// for write-protected images; click a row to mount, or Cancel). Returns the
    /// chosen image index, or -1 if cancelled.
    private async Task<int> PickImageAsync(string fileName, EmulatorHost.ImageInfo[] images)
    {
        int chosen = -1;

        var list = new ListView
        {
            SelectionMode = ListViewSelectionMode.None,
            IsItemClickEnabled = true,
        };
        for (int i = 0; i < images.Length; i++)
            list.Items.Add(MakeImageRow(i, images[i]));

        var dialog = new ContentDialog
        {
            Title = "Select Disk Image",
            Content = list,
            CloseButtonText = "Cancel",
            XamlRoot = Root.XamlRoot,
        };
        list.ItemClick += (_, e) =>
        {
            chosen = list.Items.IndexOf(e.ClickedItem);
            dialog.Hide();
        };
        await dialog.ShowAsync();
        return chosen;
    }

    /// One row of the image-selection dialog: "#i  Name … Type 🔒".
    private static Grid MakeImageRow(int index, EmulatorHost.ImageInfo info)
    {
        var grid = new Grid { ColumnSpacing = 12, MinWidth = 380 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(34) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });

        var idx = new TextBlock { Text = $"#{index}", Opacity = 0.55, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(idx, 0);

        var name = new TextBlock
        {
            Text = info.Name,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        Grid.SetColumn(name, 1);

        var type = new TextBlock { Text = info.Type, Opacity = 0.55, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(type, 2);

        var locked = new FontIcon
        {
            Glyph = "",   // Lock (Segoe Fluent Icons)
            FontSize = 12,
            Opacity = 0.7,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = info.WriteProtected ? Visibility.Visible : Visibility.Collapsed,
        };
        Grid.SetColumn(locked, 3);

        grid.Children.Add(idx);
        grid.Children.Add(name);
        grid.Children.Add(type);
        grid.Children.Add(locked);
        return grid;
    }

    /// Mount a (multi-image) file across both drives: image 0 → drive 1, image 1
    /// → drive 2 (matches the macOS "Drive 1&2" / 2-disk-game boot). Single-image
    /// files leave drive 2 empty.
    private void MountBothFromPath(string path)
    {
        if (_host is null) return;
        byte[] bytes;
        try { bytes = File.ReadAllBytes(path); }
        catch (Exception ex) { StatusText.Text = $"Mount failed: {ex.Message}"; return; }
        string name = System.IO.Path.GetFileName(path);

        int images = _host.ProbeDisk(bytes, out EmulatorHost.ImageInfo[] infos);
        if (images <= 0) { StatusText.Text = $"Failed to parse {name}"; return; }

        FillSlot(_drives[0], bytes, name, infos, 0);
        _host.MountDisk(0, bytes, 0);
        if (images >= 2)
        {
            FillSlot(_drives[1], bytes, name, infos, 1);
            _host.MountDisk(1, bytes, 1);
        }
        else
        {
            _host.EjectDisk(1);
            _drives[1] = new DriveSlot();
        }
        ApplyBootConfig();   // drive 0 occupied → FDD boot

        AddRecent(path);
        RebuildDiskMenu();
        UpdateDiskStatus();
    }

    private static void FillSlot(DriveSlot slot, byte[] bytes, string name,
                                 EmulatorHost.ImageInfo[] infos, int current)
    {
        string fileBase = System.IO.Path.GetFileNameWithoutExtension(name);
        slot.Bytes = bytes;
        slot.FileName = fileBase;
        slot.Images = infos;
        slot.ImageCount = infos.Length;
        slot.ImageNames = ResolveImageNames(infos.Select(i => i.Name).ToArray(), fileBase, infos.Length);
        slot.CurrentImage = current;
        slot.WriteProtected = current >= 0 && current < infos.Length && infos[current].WriteProtected;
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
        slot.WriteProtected = index < slot.Images.Length && slot.Images[index].WriteProtected;
        RebuildDiskMenu();
        UpdateDiskStatus();
    }

    private void OnEjectDrive0(object sender, RoutedEventArgs e) => EjectDrive(0);
    private void OnEjectDrive1(object sender, RoutedEventArgs e) => EjectDrive(1);

    private void EjectDrive(int drive)
    {
        _host?.EjectDisk(drive);
        _drives[drive] = new DriveSlot();
        RebuildDiskMenu();
        UpdateDiskStatus();
    }

    private void ToggleWriteProtect(int drive)
    {
        var slot = _drives[drive];
        if (_host is null || !slot.Occupied) return;
        slot.WriteProtected = !slot.WriteProtected;
        _host.SetWriteProtect(drive, slot.WriteProtected);
        RebuildDiskMenu();
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

    // MARK: - Disk menu construction (mirrors the macOS Disk menu)

    private void RebuildDiskMenu()
    {
        RebuildDriveMenu(0);
        RebuildDriveMenu(1);
        RebuildBothMenu();
        RebuildRecentMenu();
    }

    /// Build one drive's submenu: Mount… / Eject / Write Protect, then (when a
    /// disk is mounted) the file name and, for multi-image .d88, the image list.
    private void RebuildDriveMenu(int drive)
    {
        var sub = drive == 0 ? Drive0Sub : Drive1Sub;
        var slot = _drives[drive];
        sub.Items.Clear();

        var mount = new MenuFlyoutItem { Text = "Mount…" };
        mount.Click += drive == 0 ? OnMountDrive0 : OnMountDrive1;
        mount.KeyboardAccelerators.Add(new KeyboardAccelerator
        {
            Modifiers = VirtualKeyModifiers.Control,
            Key = drive == 0 ? VirtualKey.Number1 : VirtualKey.Number2,
        });
        sub.Items.Add(mount);

        var eject = new MenuFlyoutItem { Text = "Eject", IsEnabled = slot.Occupied };
        eject.Click += drive == 0 ? OnEjectDrive0 : OnEjectDrive1;
        sub.Items.Add(eject);

        var wp = new ToggleMenuFlyoutItem
        {
            Text = "Write Protect",
            IsEnabled = slot.Occupied,
            IsChecked = slot.WriteProtected,
        };
        wp.Click += (_, _) => ToggleWriteProtect(drive);
        sub.Items.Add(wp);

        if (slot.Occupied)
        {
            sub.Items.Add(new MenuFlyoutSeparator());
            sub.Items.Add(new MenuFlyoutItem { Text = slot.FileName, IsEnabled = false });
            if (slot.ImageCount > 1)
            {
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
    }

    /// "Drive 1&2": mount a 2-disk set across both drives, or eject both.
    private void RebuildBothMenu()
    {
        BothSub.Items.Clear();

        var mount = new MenuFlyoutItem { Text = "Mount…" };
        mount.Click += async (_, _) => await MountBothAsync();
        mount.KeyboardAccelerators.Add(new KeyboardAccelerator
        {
            Modifiers = VirtualKeyModifiers.Control,
            Key = VirtualKey.Number3,
        });
        BothSub.Items.Add(mount);

        var eject = new MenuFlyoutItem
        {
            Text = "Eject",
            IsEnabled = _drives[0].Occupied || _drives[1].Occupied,
        };
        eject.Click += (_, _) => { EjectDrive(0); EjectDrive(1); };
        BothSub.Items.Add(eject);
    }

    private void RebuildRecentMenu()
    {
        RecentSub.Items.Clear();
        if (_recent.Count == 0)
        {
            RecentSub.Items.Add(new MenuFlyoutItem { Text = "No Recent Files", IsEnabled = false });
            return;
        }
        foreach (string path in _recent)
        {
            string p = path;
            var item = new MenuFlyoutItem
            {
                Text = $"{System.IO.Path.GetFileName(p)}  —  {System.IO.Path.GetDirectoryName(p)}",
            };
            item.Click += (_, _) => MountBothFromPath(p);
            RecentSub.Items.Add(item);
        }
        RecentSub.Items.Add(new MenuFlyoutSeparator());
        var clear = new MenuFlyoutItem { Text = "Clear Recent Files" };
        clear.Click += (_, _) => { _recent.Clear(); SaveRecent(); RebuildRecentMenu(); };
        RecentSub.Items.Add(clear);
    }

    private async Task MountBothAsync()
    {
        if (_host is null) return;
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".d88");
        picker.FileTypeFilter.Add(".d77");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        StorageFile? file = await picker.PickSingleFileAsync();
        if (file is not null) MountBothFromPath(file.Path);
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
            if (slot.WriteProtected) label += " [WP]";
            parts.Add($"D{d + 1}: {label}");
        }
        StatusText.Text = parts.Count == 0 ? "No disk (→ BASIC)" : string.Join("    ", parts);
    }

    // MARK: - Recent files (MRU persisted to %LOCALAPPDATA%\Bubilator88\recent.json)

    private const int MaxRecent = 10;
    private readonly List<string> _recent = new();

    private static string RecentPath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Bubilator88", "recent.json");

    private void LoadRecent()
    {
        try
        {
            if (!File.Exists(RecentPath)) return;
            var list = System.Text.Json.JsonSerializer.Deserialize<List<string>>(File.ReadAllText(RecentPath));
            if (list is not null)
                _recent.AddRange(list.Where(File.Exists).Take(MaxRecent));
        }
        catch { /* corrupt or unreadable — start empty */ }
    }

    private void SaveRecent()
    {
        try
        {
            string? dir = System.IO.Path.GetDirectoryName(RecentPath);
            if (dir is not null) Directory.CreateDirectory(dir);
            File.WriteAllText(RecentPath, System.Text.Json.JsonSerializer.Serialize(_recent));
        }
        catch { /* best effort */ }
    }

    private void AddRecent(string path)
    {
        _recent.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
        _recent.Insert(0, path);
        while (_recent.Count > MaxRecent) _recent.RemoveAt(_recent.Count - 1);
        SaveRecent();
    }

    // MARK: - App settings (persisted to %LOCALAPPDATA%\Bubilator88\settings.json)

    private sealed class AppSettings { public int WindowScale { get; set; } = 2; }

    private static string SettingsPath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Bubilator88", "settings.json");

    private void LoadSettings()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return;
            var s = System.Text.Json.JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath));
            if (s is not null) _windowScale = Math.Clamp(s.WindowScale, 1, 3);
        }
        catch { /* corrupt or unreadable — keep defaults */ }
    }

    private void SaveSettings()
    {
        try
        {
            string? dir = System.IO.Path.GetDirectoryName(SettingsPath);
            if (dir is not null) Directory.CreateDirectory(dir);
            File.WriteAllText(SettingsPath,
                System.Text.Json.JsonSerializer.Serialize(new AppSettings { WindowScale = _windowScale }));
        }
        catch { /* best effort */ }
    }

    // MARK: - View menu

    private void OnWindowScale(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement fe && int.TryParse(fe.Tag?.ToString(), out int scale))
            ApplyWindowScale(scale);
    }

    /// Resize the window to an exact integer view multiple and (optionally)
    /// persist it. The window cannot be freely resized (see ConfigureFixedSize),
    /// so these scales are the only way to change its size.
    private void ApplyWindowScale(int scale, bool persist = true)
    {
        _windowScale = Math.Clamp(scale, 1, 3);
        if (persist) SaveSettings();
        if (_fullscreen) return;
        double rs = Root.XamlRoot?.RasterizationScale ?? 1.0;
        int w = (int)(EmulatorHost.ScreenWidth * _windowScale * rs);
        int h = (int)((EmulatorHost.ScreenHeight * _windowScale + ChromeHeightDip) * rs);
        AppWindow.Resize(new SizeInt32(w, h));
    }

    /// Forbid arbitrary user resizing/maximizing — the window only changes size
    /// via the fixed ×1/×2/×3 view scales (matches the macOS .contentSize /
    /// disabled-resize behavior). Programmatic AppWindow.Resize still works.
    private void ConfigureFixedSize()
    {
        if (AppWindow.Presenter is OverlappedPresenter op)
        {
            op.IsResizable = false;
            op.IsMaximizable = false;
        }
    }

    private void OnToggleFullscreen(object sender, RoutedEventArgs e)
    {
        _fullscreen = !_fullscreen;
        AppWindow.SetPresenter(_fullscreen
            ? AppWindowPresenterKind.FullScreen
            : AppWindowPresenterKind.Default);
        FullscreenItem.IsChecked = _fullscreen;
        if (!_fullscreen)
        {
            // The Default presenter is freshly created — re-lock it and restore
            // the saved view scale.
            ConfigureFixedSize();
            ApplyWindowScale(_windowScale, persist: false);
        }
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
