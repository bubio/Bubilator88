using System;
using System.IO;
using System.Text.Json;

namespace Bubilator88.Windows;

/// <summary>
/// App-level metadata stored beside each save state (slot_N.meta.json /
/// quicksave.meta.json), mirroring the macOS SaveMeta. The machine state itself
/// (incl. mounted disk images) lives in the .b88s blob; this sidecar carries the
/// host-side UI state needed to re-sync after a load: boot mode, clock, and the
/// per-drive display info so the disk menu/labels can be reconstructed.
/// </summary>
internal sealed class WinSaveMeta
{
    public int BootModeIndex { get; set; }      // 0=N88-V2 1=V1H 2=V1S 3=N-BASIC
    public bool Clock8MHz { get; set; } = true;

    public DriveMeta? Drive0 { get; set; }
    public DriveMeta? Drive1 { get; set; }

    internal sealed class DriveMeta
    {
        public string FileName { get; set; } = "";
        public string[] ImageNames { get; set; } = Array.Empty<string>();
        public int ImageCount { get; set; }
        public int CurrentImage { get; set; }
        public bool WriteProtected { get; set; }
        public string? SourcePath { get; set; }   // re-read for multi-image switching
    }
}

/// <summary>
/// Resolves the on-disk layout of save states and reads their sidecar metadata.
/// Layout matches macOS: %LOCALAPPDATA%\Bubilator88\SaveStates\ with, per entry,
/// a .b88s machine blob, a .meta.json sidecar, and a .thumb.png 320×200 preview.
/// Slot −1 is the quick-save; slots 0..9 are the numbered save-state slots.
/// </summary>
internal static class WinSaveState
{
    public const int SlotCount = 10;

    public static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Bubilator88", "SaveStates");

    private static string Base(int slot) => slot < 0 ? "quicksave" : $"slot_{slot}";

    public static string StatePath(int slot) => Path.Combine(Dir, Base(slot) + ".b88s");
    public static string MetaPath(int slot) => Path.Combine(Dir, Base(slot) + ".meta.json");
    public static string ThumbPath(int slot) => Path.Combine(Dir, Base(slot) + ".thumb.png");

    public static bool Exists(int slot) => File.Exists(StatePath(slot));

    public static DateTime? ModifiedAt(int slot)
    {
        try { return Exists(slot) ? File.GetLastWriteTime(StatePath(slot)) : null; }
        catch { return null; }
    }

    public static WinSaveMeta? ReadMeta(int slot)
    {
        try
        {
            string p = MetaPath(slot);
            if (!File.Exists(p)) return null;
            return JsonSerializer.Deserialize<WinSaveMeta>(File.ReadAllText(p));
        }
        catch { return null; }
    }

    public static void WriteMeta(int slot, WinSaveMeta meta)
    {
        Directory.CreateDirectory(Dir);
        File.WriteAllText(MetaPath(slot), JsonSerializer.Serialize(meta));
    }
}
