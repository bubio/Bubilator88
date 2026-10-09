using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Bubilator88.Windows;

/// <summary>
/// 88PAR cheat codes (port of the macOS Cheats menu). A <c>.pat</c> file or a bundled
/// preset is stored in <see cref="CheatStore"/> for the mounted disks; the set for the
/// disk in drive 1 (else drive 2) is active, and its enabled groups run once per frame
/// before the frame, from <see cref="EmulatorHost"/>.
/// </summary>
public sealed partial class MainWindow
{
    private CheatStore? _cheats;

    private CheatStore Cheats => _cheats ??= new CheatStore(
        System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Bubilator88", "Cheats.json"),
        CheatStore.LoadPresets(DeploymentFiles.Find("CheatPresets.json")));

    /// <summary>File names of the mounted disks, drive 1 first.</summary>
    private string?[] CheatDiskFiles => _drives
        .Select(d => !d.Occupied ? null
            : d.SourcePath is { } p ? System.IO.Path.GetFileName(p) : d.FileName)
        .ToArray();

    private CheatSet? ActiveCheatSet => Cheats.SetFor(CheatDiskFiles);

    /// <summary>Rebuild the Cheats menu and hand the host the codes it should run.
    /// Call it whenever the mounted disks or the store change.</summary>
    private void RebuildCheatMenu()
    {
        CheatSet? set = ActiveCheatSet;
        _host?.SetCheatCodes(set is null ? Array.Empty<byte[]>() : Cheats.EnabledCodes(set));

        // MenuBarItem.Items.Clear() leaves the old items showing; remove one by one.
        while (CheatsMenu.Items.Count > 0) CheatsMenu.Items.RemoveAt(CheatsMenu.Items.Count - 1);
        if (set is not null)
        {
            // Notes go in each item's tooltip: many codes mean nothing without them.
            var header = new MenuFlyoutItem { Text = set.Name, IsEnabled = false };
            AddNotesTip(header, PatFile.HeaderNotes(set.Text));
            CheatsMenu.Items.Add(header);

            var groups = Cheats.Groups(set);
            for (int i = 0; i < groups.Count; i++)
            {
                int index = i;
                var item = new ToggleMenuFlyoutItem
                {
                    Text = groups[i].Name.Length == 0 ? PatFile.UnnamedGroupName : groups[i].Name,
                    IsChecked = set.EnabledGroups.Contains(i),
                };
                AddNotesTip(item, groups[i].Notes);
                item.Click += (_, _) =>
                {
                    Cheats.SetGroup(set, index, item.IsChecked);
                    RebuildCheatMenu();
                };
                CheatsMenu.Items.Add(item);
            }
            CheatsMenu.Items.Add(new MenuFlyoutSeparator());

            var disableAll = new MenuFlyoutItem { Text = "Disable All Cheats", IsEnabled = set.EnabledGroups.Count > 0 };
            disableAll.Click += (_, _) =>
            {
                Cheats.DisableAll(set);
                RebuildCheatMenu();
            };
            CheatsMenu.Items.Add(disableAll);
            CheatsMenu.Items.Add(new MenuFlyoutSeparator());
        }

        bool noDisk = CheatDiskFiles.All(f => f is null);
        var presets = new MenuFlyoutSubItem { Text = "Presets", IsEnabled = !noDisk };
        foreach (CheatPreset preset in Cheats.Presets)
        {
            var item = new MenuFlyoutItem { Text = preset.Title };
            item.Click += (_, _) => UseCheatPreset(preset);
            presets.Items.Add(item);
        }
        if (presets.Items.Count == 0) presets.IsEnabled = false;
        CheatsMenu.Items.Add(presets);

        var import = new MenuFlyoutItem { Text = "Import Cheat File…", IsEnabled = !noDisk };
        import.Click += async (_, _) => await ImportCheatFileAsync();
        CheatsMenu.Items.Add(import);
    }

    private static void AddNotesTip(FrameworkElement item, System.Collections.Generic.List<string> notes)
    {
        if (notes.Count > 0) ToolTipService.SetToolTip(item, string.Join("\n", notes));
    }

    /// <summary>Use a bundled preset for every mounted disk file. Its groups start off,
    /// so nothing is applied yet: reopening the menu shows the groups to switch on.</summary>
    private void UseCheatPreset(CheatPreset preset)
    {
        string[]? diskFiles = CheatTargetDiskFiles();
        if (diskFiles is null) { _ = ShowCheatErrorAsync("Mount the game's disk first. Cheat codes are kept for the mounted disks."); return; }
        Cheats.Import(preset.Title, preset.Text, diskFiles, preset.Title);
        RebuildCheatMenu();
    }

    /// <summary>Choose a <c>.pat</c> file and import it for every mounted disk file.</summary>
    private async Task ImportCheatFileAsync()
    {
        string[]? diskFiles = CheatTargetDiskFiles();
        if (diskFiles is null) { await ShowCheatErrorAsync("Mount the game's disk first. Cheat codes are kept for the mounted disks."); return; }

        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".pat");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        StorageFile? file = await picker.PickSingleFileAsync();
        if (file is null) return;

        string text;
        try { text = PatFile.DecodeText(await File.ReadAllBytesAsync(file.Path)); }
        catch (Exception ex) { await ShowCheatErrorAsync(ex.Message); return; }
        if (!PatFile.Parse(text).Any(g => g.Codes.Count > 0))
        {
            await ShowCheatErrorAsync("The file contains no cheat codes.");
            return;
        }
        Cheats.Import(file.Name, text, diskFiles);
        RebuildCheatMenu();
        ShowToast($"Cheat file imported: {file.Name}");
    }

    /// <summary>The mounted disk files, each once, or null when no disk is mounted.</summary>
    private string[]? CheatTargetDiskFiles()
    {
        var files = new System.Collections.Generic.List<string>();
        foreach (string? f in CheatDiskFiles)
            if (f is not null && !files.Any(x => CheatSet.SameFile(x, f))) files.Add(f);
        return files.Count == 0 ? null : files.ToArray();
    }

    private Task ShowCheatErrorAsync(string message)
        => ShowDialogAsync(new ContentDialog
        {
            Title = "Cannot Import Cheat File",
            Content = message,
            CloseButtonText = "OK",
            XamlRoot = Root.XamlRoot,
        });
}
