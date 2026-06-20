using System;
using System.Runtime.InteropServices;

namespace Bubilator88.Windows;

/// <summary>
/// P/Invoke bindings for the Swift emulation core (Bubilator88C.dll, built from
/// Packages/EmulatorCore/Sources/CApi/CApi.swift). This is the ONLY boundary
/// between the managed shell and the native core — every signature here must
/// match a <c>@_cdecl</c> export exactly.
///
/// All buffer-passing entry points take raw pointers so the hot path (render /
/// audio drain) is zero-copy and allocation-free — see the GC notes in
/// docs/WINDOWS_PORT.md. We use <see cref="LibraryImportAttribute"/> (source
/// generated, blittable-only) to avoid the classic Marshal copy.
/// </summary>
internal static unsafe partial class NativeApi
{
    private const string Dll = "Bubilator88C";

    // ROM kind selectors for b88_load_rom.
    public const int RomN88 = 0;
    public const int RomN80 = 1;
    public const int RomDisk = 2;
    public const int RomFont = 3;
    public const int RomKanji1 = 4;
    public const int RomKanji2 = 5;
    public const int RomN88Ext0 = 10; // +0..+3 for banks 0..3

    // DIP SW2 base values (boot mode).
    public const int DipSw2_V2 = 0x71;
    public const int DipSw2_V1H = 0xF1;
    public const int DipSw2_V1S = 0xB1;
    // DIP SW1.
    public const int DipSw1_N88 = 0xC3;
    public const int DipSw1_NBasic = 0xC2;

    [LibraryImport(Dll)]
    public static partial IntPtr b88_create();

    [LibraryImport(Dll)]
    public static partial void b88_destroy(IntPtr handle);

    [LibraryImport(Dll)]
    public static partial void b88_load_rom(IntPtr handle, int kind, byte* ptr, int len);

    [LibraryImport(Dll)]
    public static partial int b88_mount_disk(IntPtr handle, int drive, byte* ptr, int len, int imageIndex);

    [LibraryImport(Dll)]
    public static partial void b88_eject_disk(IntPtr handle, int drive);

    [LibraryImport(Dll)]
    public static partial int b88_d88_probe(byte* ptr, int len, byte* outUtf8, int outCap);

    [LibraryImport(Dll)]
    public static partial void b88_set_dipsw1(IntPtr handle, int value);

    [LibraryImport(Dll)]
    public static partial void b88_apply_bootstrap(IntPtr handle, int dipsw2Base);

    [LibraryImport(Dll)]
    public static partial void b88_reset(IntPtr handle, int preserveRam);

    [LibraryImport(Dll)]
    public static partial void b88_set_clock_8mhz(IntPtr handle, int on);

    [LibraryImport(Dll)]
    public static partial int b88_run_frame(IntPtr handle);

    [LibraryImport(Dll)]
    public static partial void b88_press_key(IntPtr handle, int row, int bit);

    [LibraryImport(Dll)]
    public static partial void b88_release_key(IntPtr handle, int row, int bit);

    [LibraryImport(Dll)]
    public static partial int b88_render_rgba(IntPtr handle, byte* outPtr, int outLen, int blinkCursor);

    [LibraryImport(Dll)]
    public static partial int b88_drain_audio(IntPtr handle, float* outPtr, int maxPairs);

    [LibraryImport(Dll)]
    public static partial void b88_audio_rate_control(IntPtr handle, int fillPairs, int capacityPairs);

    [LibraryImport(Dll)]
    public static partial void b88_disk_access(IntPtr handle, int* out0, int* out1);
}
