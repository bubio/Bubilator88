using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bubilator88.Windows;

// 88PAR cheat codes: a port of the macOS CheatStore plus the .pat reader of
// Bubilator88Core (PATFile). The core only runs codes (b88_pat_run); reading
// the text stays on this side, so the C ABI carries no strings.

/// <summary>One line of a <c>.pat</c> file: <c>TTaabbbb vvvv</c>.</summary>
internal readonly record struct PatCode(byte Opcode, byte Area, ushort Address, ushort Value);

/// <summary>A named group of codes, switched on and off as one.</summary>
internal sealed class PatGroup
{
    public string Name { get; init; } = "";
    public List<PatCode> Codes { get; } = new();
    /// <summary>The <c>;</c> comment lines between the <c>#</c> line and the
    /// group's first code, without the <c>;</c>. pat.dll ignores them.</summary>
    public List<string> Notes { get; } = new();
}

internal static class PatFile
{
    /// <summary>pat.dll keeps at most this many groups and drops everything after
    /// the group that would exceed it.</summary>
    public const int MaxGroups = 15;

    /// <summary>The name of the group that codes before the first <c>#</c> line fall into.</summary>
    public const string UnnamedGroupName = "No Name";

    /// <summary>Bytes per code in <c>b88_pat_run</c>'s buffer.</summary>
    public const int PackedCodeSize = 6;

    /// <summary>The file's text. <c>.pat</c> files are Shift_JIS, or UTF-16 with a
    /// BOM; UTF-8 is accepted as well. Bytes that fit none of these are read as
    /// Latin-1, which keeps the hex codes intact whatever happens to the names.</summary>
    public static string DecodeText(byte[] data)
    {
        if (data.Length >= 2 && ((data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF)))
        {
            Encoding utf16 = data[0] == 0xFF ? Encoding.Unicode : Encoding.BigEndianUnicode;
            return utf16.GetString(data, 2, data.Length - 2);
        }
        if (data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF)
        {
            try { return new UTF8Encoding(false, true).GetString(data, 3, data.Length - 3); }
            catch (ArgumentException) { }
        }
        try { return new UTF8Encoding(false, true).GetString(data); }
        catch (ArgumentException) { }
        try
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            return Encoding.GetEncoding(932, EncoderFallback.ExceptionFallback, DecoderFallback.ExceptionFallback)
                           .GetString(data);
        }
        catch (ArgumentException) { }
        return Encoding.Latin1.GetString(data);
    }

    private const string CodeLineStarts = "0123456789abcdefABCDEFwW+-=!<>";

    /// <summary>Mnemonic prefixes, which stand for the opcode byte. The second
    /// character gives the width: <c>w</c> for 16-bit, <c>b</c> for 8-bit.</summary>
    private static readonly Dictionary<string, string> Mnemonics = new()
    {
        ["ww"] = "80", ["Ww"] = "81", ["+w"] = "10", ["-w"] = "11",
        ["=w"] = "D0", ["!w"] = "D1", ["<w"] = "D2", [">w"] = "D3",
        ["wb"] = "30", ["Wb"] = "31", ["+b"] = "20", ["-b"] = "21",
        ["=b"] = "E0", ["!b"] = "E1", ["<b"] = "E2", [">b"] = "E3",
        ["cp"] = "C2",
    };

    /// <summary>The groups in a <c>.pat</c> file's text. Mirrors pat.dll's reader:
    /// <c>;</c> lines are comments, a <c>#</c> line begins a named group, a line
    /// starting with a hex digit or one of <c>wW+-=!&lt;&gt;</c> is a code and any other
    /// line is dropped silently. A malformed operand reads as 0 rather than failing.</summary>
    public static List<PatGroup> Parse(string text)
    {
        var groups = new List<PatGroup>();
        foreach (string line in text.Split(new[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
        {
            char first = line[0];
            if (first == ';')
            {
                if (groups.Count > 0 && groups[^1].Codes.Count == 0)
                {
                    string note = line[1..].Trim(' ', '\t');
                    if (note.Length > 0) groups[^1].Notes.Add(note);
                }
                continue;
            }
            if (first == '#')
            {
                if (groups.Count >= MaxGroups) break;
                groups.Add(new PatGroup { Name = line[1..].Trim(' ', '\t') });
                continue;
            }
            if (CodeLineStarts.IndexOf(first) < 0) continue;
            if (groups.Count == 0) groups.Add(new PatGroup { Name = UnnamedGroupName });
            groups[^1].Codes.Add(ParseCode(line));
        }
        return groups;
    }

    /// <summary>The <c>;</c> comment lines at the top of the file, before any group
    /// or code: notes about the whole game.</summary>
    public static List<string> HeaderNotes(string text)
    {
        var notes = new List<string>();
        foreach (string line in text.Split(new[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (line[0] != ';') break;
            string note = line[1..].Trim(' ', '\t');
            if (note.Length > 0) notes.Add(note);
        }
        return notes;
    }

    private static PatCode ParseCode(string line)
    {
        int pos = 0;
        string head = TakeField(line, ref pos, 8);
        if (head.Length >= 2 && Mnemonics.TryGetValue(head[..2], out string? opcode))
            head = opcode + head[2..];
        uint word = HexPrefix(head);
        uint value = HexPrefix(TakeField(line, ref pos, 4));
        return new PatCode((byte)(word >> 24), (byte)(word >> 16), (ushort)word, (ushort)value);
    }

    /// <summary>Skip control characters and spaces, then take up to <paramref name="length"/> characters.</summary>
    private static string TakeField(string s, ref int pos, int length)
    {
        while (pos < s.Length && s[pos] <= ' ') pos++;
        int n = Math.Min(length, s.Length - pos);
        string field = s.Substring(pos, n);
        pos += n;
        return field;
    }

    /// <summary>The value of the hex digits at the start of <paramref name="field"/>, 0 if there are none.</summary>
    private static uint HexPrefix(string field)
    {
        uint v = 0;
        foreach (char c in field)
        {
            int d = c is >= '0' and <= '9' ? c - '0'
                  : c is >= 'a' and <= 'f' ? c - 'a' + 10
                  : c is >= 'A' and <= 'F' ? c - 'A' + 10 : -1;
            if (d < 0) break;
            v = (v << 4) | (uint)d;
        }
        return v;
    }

    /// <summary>The codes as <c>b88_pat_run</c> takes them: 6 bytes each, little-endian.</summary>
    public static byte[] Pack(IEnumerable<PatCode> codes)
    {
        var bytes = new List<byte>();
        foreach (PatCode c in codes)
        {
            bytes.Add(c.Opcode);
            bytes.Add(c.Area);
            bytes.Add((byte)c.Address);
            bytes.Add((byte)(c.Address >> 8));
            bytes.Add((byte)c.Value);
            bytes.Add((byte)(c.Value >> 8));
        }
        return bytes.ToArray();
    }
}

/// <summary>An imported <c>.pat</c> file and the disks it is for. The file's text is
/// kept rather than its path, so the codes survive the file moving or being deleted.
/// Disks are matched by file name alone, like QUASI88's <c>&lt;disk&gt;.pat</c> lookup.</summary>
internal sealed class CheatSet
{
    public Guid Id { get; set; } = Guid.NewGuid();
    /// <summary>The imported file's name, shown as the menu's heading.</summary>
    public string Name { get; set; } = "";
    public string Text { get; set; } = "";
    /// <summary>Disk file names this set applies to.</summary>
    public List<string> DiskFiles { get; set; } = new();
    /// <summary>Indices of the groups switched on, remembered across launches.</summary>
    public List<int> EnabledGroups { get; set; } = new();
    /// <summary>The title of the bundled preset this set was made from, if any.
    /// Such a set follows the bundle: the store replaces its text when the preset changes.</summary>
    public string? Preset { get; set; }

    public bool Applies(string fileName) => DiskFiles.Any(f => SameFile(f, fileName));

    /// <summary>File names match ignoring case and Unicode normalization.</summary>
    public static bool SameFile(string a, string b)
        => string.Equals(a.Normalize(NormalizationForm.FormC), b.Normalize(NormalizationForm.FormC),
                         StringComparison.OrdinalIgnoreCase);
}

/// <summary>A game's codes bundled with the app, in <c>.pat</c> form.</summary>
internal sealed class CheatPreset
{
    public string Title { get; set; } = "";
    public string Text { get; set; } = "";
}

/// <summary>
/// Imported cheat files, persisted as one JSON file written on every change. The
/// bundled presets are offered for the user to pick: disk file names differ from
/// copy to copy, so a preset cannot find its game by itself. Picking one copies it
/// into a set like an imported file, which remembers the preset and takes its text
/// again on load whenever a newer bundle has changed it.
/// </summary>
internal sealed class CheatStore
{
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
    };

    private sealed class StoredFile { public List<CheatSet> Sets { get; set; } = new(); }
    private sealed class PresetFile { public List<CheatPreset> Presets { get; set; } = new(); }

    private readonly string _filePath;
    private readonly Dictionary<Guid, List<PatGroup>> _parsed = new();

    public IReadOnlyList<CheatPreset> Presets { get; }
    public List<CheatSet> Sets { get; private set; } = new();

    public CheatStore(string filePath, IReadOnlyList<CheatPreset>? presets = null)
    {
        _filePath = filePath;
        Presets = presets ?? Array.Empty<CheatPreset>();
        Load();
    }

    /// <summary>The presets in <c>CheatPresets.json</c>, sorted by title. Empty if unreadable.</summary>
    public static List<CheatPreset> LoadPresets(string? path)
    {
        if (path is null || !File.Exists(path)) return new List<CheatPreset>();
        try
        {
            var file = JsonSerializer.Deserialize<PresetFile>(File.ReadAllText(path, Encoding.UTF8), Json);
            return (file?.Presets ?? new List<CheatPreset>())
                .OrderBy(p => p.Title, StringComparer.CurrentCulture).ToList();
        }
        catch { return new List<CheatPreset>(); }
    }

    /// <summary>The set for the first of <paramref name="diskFiles"/> that has one.
    /// Callers pass drive 1 then drive 2, so the boot disk decides.</summary>
    public CheatSet? SetFor(IEnumerable<string?> diskFiles)
    {
        foreach (string? file in diskFiles)
        {
            if (file is null) continue;
            CheatSet? found = Sets.FirstOrDefault(s => s.Applies(file));
            if (found is not null) return found;
        }
        return null;
    }

    /// <summary>Parsed groups, cached so menus do not reparse on every rebuild.</summary>
    public List<PatGroup> Groups(CheatSet set)
    {
        if (!_parsed.TryGetValue(set.Id, out List<PatGroup>? groups))
            _parsed[set.Id] = groups = PatFile.Parse(set.Text);
        return groups;
    }

    /// <summary>The packed codes of the groups switched on, one buffer per group, in group order.</summary>
    public List<byte[]> EnabledCodes(CheatSet set)
    {
        List<PatGroup> groups = Groups(set);
        return Enumerable.Range(0, groups.Count)
            .Where(set.EnabledGroups.Contains)
            .Select(i => PatFile.Pack(groups[i].Codes))
            .Where(b => b.Length > 0)
            .ToList();
    }

    /// <summary>Add a set for <paramref name="diskFiles"/>, all its groups off. The disks
    /// leave whatever set they had, and a set left with no disks is dropped.</summary>
    public CheatSet Import(string name, string text, IReadOnlyList<string> diskFiles, string? preset = null)
    {
        foreach (CheatSet s in Sets)
            s.DiskFiles.RemoveAll(f => diskFiles.Any(d => CheatSet.SameFile(d, f)));
        Sets.RemoveAll(s => s.DiskFiles.Count == 0);
        var set = new CheatSet { Name = name, Text = text, DiskFiles = diskFiles.ToList(), Preset = preset };
        Sets.Add(set);
        var ids = Sets.Select(s => s.Id).ToHashSet();
        foreach (Guid id in _parsed.Keys.Where(k => !ids.Contains(k)).ToList()) _parsed.Remove(id);
        Save();
        return set;
    }

    public void SetGroup(CheatSet set, int index, bool enabled)
    {
        if (enabled) { if (!set.EnabledGroups.Contains(index)) set.EnabledGroups.Add(index); }
        else set.EnabledGroups.Remove(index);
        Save();
    }

    public void DisableAll(CheatSet set)
    {
        set.EnabledGroups.Clear();
        Save();
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_filePath)) return;
            Sets = JsonSerializer.Deserialize<StoredFile>(File.ReadAllText(_filePath, Encoding.UTF8), Json)?.Sets
                   ?? new List<CheatSet>();
        }
        catch { Sets = new List<CheatSet>(); return; }
        if (FollowPresets()) Save();
    }

    /// <summary>Bring sets made from a preset up to the bundled text. Groups stay on
    /// where a group of the same name survives. Returns whether anything changed.</summary>
    private bool FollowPresets()
    {
        bool changed = false;
        foreach (CheatSet set in Sets)
        {
            if (set.Preset is null) continue;
            CheatPreset? preset = Presets.FirstOrDefault(p => p.Title == set.Preset);
            if (preset is null || preset.Text == set.Text) continue;
            List<PatGroup> old = PatFile.Parse(set.Text);
            var enabledNames = set.EnabledGroups.Where(i => i >= 0 && i < old.Count)
                                   .Select(i => old[i].Name).ToHashSet();
            List<PatGroup> now = PatFile.Parse(preset.Text);
            set.Text = preset.Text;
            set.EnabledGroups = Enumerable.Range(0, now.Count).Where(i => enabledNames.Contains(now[i].Name)).ToList();
            _parsed.Remove(set.Id);
            changed = true;
        }
        return changed;
    }

    private void Save()
    {
        try
        {
            string? dir = Path.GetDirectoryName(_filePath);
            if (dir is not null) Directory.CreateDirectory(dir);
            string tmp = _filePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(new StoredFile { Sets = Sets }, Json), new UTF8Encoding(false));
            File.Move(tmp, _filePath, overwrite: true);
        }
        catch { /* best effort, like the settings file */ }
    }
}
