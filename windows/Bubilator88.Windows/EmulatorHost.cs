using System;
using System.IO;
using Windows.System;

namespace Bubilator88.Windows;

/// <summary>
/// Managed lifetime wrapper around one native <c>B88Context</c>. Owns the
/// reusable pixel + audio scratch buffers so the per-frame path never
/// allocates. Not thread-safe; drive it from a single (UI) thread.
/// </summary>
internal sealed unsafe class EmulatorHost : IDisposable
{
    public const int ScreenWidth = 640;
    public const int ScreenHeight = 400;
    private const int PixelBytes = ScreenWidth * ScreenHeight * 4;
    private const int AudioMaxPairs = 4096;
    // Target output latency for adaptive rate control (~40 ms = half of this).
    private const int AudioTargetCapacityPairs = (int)(SampleRate * 0.08);
    private const int SampleRate = 44100;

    /// <summary>Peak |sample| of the most recent audio drain (0..1), for a UI level meter.</summary>
    public float LastPeak { get; private set; }

    private IntPtr _handle;

    // Pre-allocated, reused every frame (zero per-frame GC pressure).
    private readonly byte[] _pixels = new byte[PixelBytes];
    private readonly float[] _audio = new float[AudioMaxPairs * 2];

    public ReadOnlySpan<byte> Pixels => _pixels;

    public EmulatorHost()
    {
        _handle = NativeApi.b88_create();
        if (_handle == IntPtr.Zero)
            throw new InvalidOperationException("b88_create returned null — is Bubilator88C.dll present?");
    }

    /// <summary>
    /// Load ROM files from <paramref name="romDir"/> (defaults to
    /// %LOCALAPPDATA%\Bubilator88). N88.ROM is required; the rest are optional.
    /// </summary>
    public void LoadRoms(string? romDir = null)
    {
        romDir ??= Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Bubilator88");

        LoadRom(romDir, "N88.ROM", NativeApi.RomN88, required: true);
        LoadRom(romDir, "N80.ROM", NativeApi.RomN80);
        LoadRom(romDir, "DISK.ROM", NativeApi.RomDisk);
        LoadRom(romDir, "FONT.ROM", NativeApi.RomFont);
        LoadRom(romDir, "KANJI1.ROM", NativeApi.RomKanji1);
        LoadRom(romDir, "KANJI2.ROM", NativeApi.RomKanji2);
        for (int bank = 0; bank < 4; bank++)
            LoadRom(romDir, $"N88_{bank}.ROM", NativeApi.RomN88Ext0 + bank);

        LoadRhythmSamples(romDir);
    }

    // YM2608 rhythm WAV samples (fmgen format: signed 16-bit PCM). Without these
    // the OPNA rhythm channels are silent. File order must match the core's
    // index convention (0=BD 1=SD 2=TOP 3=HH 4=TOM 5=RIM). Mirrors macOS
    // EmulatorViewModel+Disk.swift.
    private static readonly string[] RhythmFiles =
        { "2608_BD.WAV", "2608_SD.WAV", "2608_TOP.WAV", "2608_HH.WAV", "2608_TOM.WAV", "2608_RIM.WAV" };

    private void LoadRhythmSamples(string dir)
    {
        for (int i = 0; i < RhythmFiles.Length; i++)
        {
            string path = Path.Combine(dir, RhythmFiles[i]);
            if (!File.Exists(path)) continue;
            byte[] data = File.ReadAllBytes(path);
            fixed (byte* p = data)
                NativeApi.b88_load_rhythm_sample(_handle, i, p, data.Length);
        }
    }

    private void LoadRom(string dir, string name, int kind, bool required = false)
    {
        string path = Path.Combine(dir, name);
        if (!File.Exists(path))
        {
            if (required)
                throw new FileNotFoundException($"Required ROM missing: {path}");
            return;
        }
        byte[] data = File.ReadAllBytes(path);
        fixed (byte* p = data)
            NativeApi.b88_load_rom(_handle, kind, p, data.Length);
    }

    /// <summary>Mount a D88 image. Returns image count in the blob.</summary>
    public int MountDisk(int drive, byte[] d88, int imageIndex = 0)
    {
        fixed (byte* p = d88)
            return NativeApi.b88_mount_disk(_handle, drive, p, d88.Length, imageIndex);
    }

    /// <summary>Per-image metadata returned by <see cref="ProbeDisk"/>.</summary>
    public readonly record struct ImageInfo(string Name, string Type, bool WriteProtected);

    /// <summary>
    /// Probe a (multi-image) D88 blob without mounting. Returns the image count
    /// and per-image metadata (embedded name, disk type label, write-protect).
    /// </summary>
    public int ProbeDisk(byte[] d88, out ImageInfo[] images)
    {
        const int Cap = 8192;
        byte* o = stackalloc byte[Cap];
        int count;
        fixed (byte* p = d88)
            count = NativeApi.b88_d88_probe(p, d88.Length, o, Cap);

        if (count <= 0)
        {
            images = Array.Empty<ImageInfo>();
            return count;
        }
        int end = 0;
        while (end < Cap && o[end] != 0) end++;
        string joined = end > 0 ? System.Text.Encoding.UTF8.GetString(o, end) : "";
        string[] lines = joined.Length > 0 ? joined.Split('\n') : Array.Empty<string>();

        images = new ImageInfo[count];
        for (int i = 0; i < count; i++)
        {
            string name = "", type = "2D";
            bool wp = false;
            if (i < lines.Length)
            {
                string[] f = lines[i].Split('\t');
                if (f.Length > 0) name = f[0];
                if (f.Length > 1) type = TypeLabel(f[1]);
                if (f.Length > 2) wp = f[2] == "1";
            }
            images[i] = new ImageInfo(name, type, wp);
        }
        return count;
    }

    private static string TypeLabel(string raw) => raw switch
    {
        "16" => "2DD",
        "32" => "2HD",
        _ => "2D",
    };

    public void EjectDisk(int drive) => NativeApi.b88_eject_disk(_handle, drive);

    public void SetWriteProtect(int drive, bool protectedFlag)
        => NativeApi.b88_set_write_protect(_handle, drive, protectedFlag ? 1 : 0);

    /// <summary>
    /// Sample and clear the per-drive disk-access flags (drives 0 and 1).
    /// Each flag pulses true while the FDC touched that drive since the last
    /// call — drive the status-bar activity LEDs from it.
    /// </summary>
    public void SampleDiskAccess(out bool drive0, out bool drive1)
    {
        int a = 0, b = 0;
        NativeApi.b88_disk_access(_handle, &a, &b);
        drive0 = a != 0;
        drive1 = b != 0;
    }

    /// <summary>
    /// Configure boot mode and reset. Mount disks BEFORE calling so the boot
    /// strap (DIP SW2 bit 3) picks FDD boot when drive 0 is occupied.
    /// </summary>
    public void Configure(bool clock8MHz, int dipSw1, int dipSw2Base)
    {
        NativeApi.b88_set_dipsw1(_handle, dipSw1);
        NativeApi.b88_apply_bootstrap(_handle, dipSw2Base);
        NativeApi.b88_reset(_handle, 0);
        // Set the clock AFTER reset: Machine.reset() forces clock8MHz = true,
        // so configuring the clock before the reset would be clobbered back to
        // 8 MHz. This mirrors the macOS ordering in EmulatorViewModel (reset,
        // then assign clock8MHz).
        NativeApi.b88_set_clock_8mhz(_handle, clock8MHz ? 1 : 0);
    }

    public void Reset(bool preserveRam = false) => NativeApi.b88_reset(_handle, preserveRam ? 1 : 0);

    /// <summary>Run one frame and composite into the internal pixel buffer.</summary>
    public void RunFrameAndRender(bool blinkCursor)
    {
        NativeApi.b88_run_frame(_handle);
        fixed (byte* p = _pixels)
            NativeApi.b88_render_rgba(_handle, p, _pixels.Length, blinkCursor ? 1 : 0);
    }

    /// <summary>
    /// Drain available audio into <paramref name="sink"/>. Returns pairs drained.
    /// </summary>
    public int DrainAudio(XAudioSink sink)
    {
        int pairs;
        fixed (float* p = _audio)
            pairs = NativeApi.b88_drain_audio(_handle, p, AudioMaxPairs);
        if (pairs > 0)
        {
            sink.Submit(_audio, pairs * 2);

            float peak = 0f;
            int n = pairs * 2;
            for (int i = 0; i < n; i++)
            {
                float a = Math.Abs(_audio[i]);
                if (a > peak) peak = a;
            }
            // Decay so the meter falls smoothly between bursts.
            LastPeak = peak > LastPeak ? peak : LastPeak * 0.85f;
        }
        else
        {
            LastPeak *= 0.85f;
        }

        // Keep XAudio2's queued latency near target so producer/consumer don't drift.
        NativeApi.b88_audio_rate_control(_handle, sink.QueuedPairs, AudioTargetCapacityPairs);
        return pairs;
    }

    /// <summary>Press a key. Returns true if the key mapped to the matrix.</summary>
    public bool KeyDown(VirtualKey key)
    {
        if (!KeyMapping.TryMap(key, out var m)) return false;
        NativeApi.b88_press_key(_handle, m.Row, m.Bit);
        return true;
    }

    /// <summary>Release a key. Returns true if the key mapped to the matrix.</summary>
    public bool KeyUp(VirtualKey key)
    {
        if (!KeyMapping.TryMap(key, out var m)) return false;
        NativeApi.b88_release_key(_handle, m.Row, m.Bit);
        return true;
    }

    public void Dispose()
    {
        if (_handle != IntPtr.Zero)
        {
            NativeApi.b88_destroy(_handle);
            _handle = IntPtr.Zero;
        }
        GC.SuppressFinalize(this);
    }
}
