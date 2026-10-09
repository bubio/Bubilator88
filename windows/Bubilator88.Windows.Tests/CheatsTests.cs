using System;
using System.IO;
using System.Linq;
using System.Text;
using Xunit;

namespace Bubilator88.Windows.Tests;

public class CheatsTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "b88-cheats-" + Guid.NewGuid());

    public CheatsTests() => Directory.CreateDirectory(_dir);
    public void Dispose() { try { Directory.Delete(_dir, true); } catch { } }

    private string StorePath => Path.Combine(_dir, "Cheats.json");

    private const string Sample =
        "; game-wide note\n" +
        "#HP MAX\n" +
        "; fills HP\n" +
        "0000C000 00FF\r\n" +
        "ww00D100 1234\n" +
        "#Second\n" +
        "E1000100 0001\n";

    [Fact]
    public void Parse_ReadsGroupsNotesAndCodes()
    {
        var groups = PatFile.Parse(Sample);
        Assert.Equal(2, groups.Count);
        Assert.Equal("HP MAX", groups[0].Name);
        Assert.Equal(new[] { "fills HP" }, groups[0].Notes);
        Assert.Equal(new PatCode(0x00, 0x00, 0xC000, 0x00FF), groups[0].Codes[0]);
        // "ww" is the 16-bit write mnemonic for opcode 80.
        Assert.Equal(new PatCode(0x80, 0x00, 0xD100, 0x1234), groups[0].Codes[1]);
        Assert.Equal(new PatCode(0xE1, 0x00, 0x0100, 0x0001), groups[1].Codes[0]);
        Assert.Equal(new[] { "game-wide note" }, PatFile.HeaderNotes(Sample));
    }

    [Fact]
    public void Parse_CodesBeforeFirstHeaderFallIntoNoName_AndMalformedOperandIsZero()
    {
        var groups = PatFile.Parse("0000C000 zz\ngarbage line\n");
        Assert.Single(groups);
        Assert.Equal(PatFile.UnnamedGroupName, groups[0].Name);
        Assert.Equal(new PatCode(0, 0, 0xC000, 0), Assert.Single(groups[0].Codes));
    }

    [Fact]
    public void Parse_StopsAtMaxGroups()
    {
        string text = string.Concat(Enumerable.Range(0, 20).Select(i => $"#G{i}\n0000C000 0001\n"));
        Assert.Equal(PatFile.MaxGroups, PatFile.Parse(text).Count);
    }

    [Fact]
    public void Pack_IsSixLittleEndianBytesPerCode()
        => Assert.Equal(new byte[] { 0x80, 0x01, 0x00, 0xD1, 0x34, 0x12 },
                        PatFile.Pack(new[] { new PatCode(0x80, 0x01, 0xD100, 0x1234) }));

    [Fact]
    public void DecodeText_HandlesUtf8Utf16AndShiftJis()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        const string text = "#体力\n0000C000 00FF\n";
        Assert.Equal(text, PatFile.DecodeText(Encoding.UTF8.GetBytes(text)));
        Assert.Equal(text, PatFile.DecodeText(Encoding.GetEncoding(932).GetBytes(text)));
        var utf16 = Encoding.Unicode.GetPreamble().Concat(Encoding.Unicode.GetBytes(text)).ToArray();
        Assert.Equal(text, PatFile.DecodeText(utf16));
    }

    [Fact]
    public void Store_MatchesDisksByFileName_IgnoringCase_AndPersists()
    {
        var store = new CheatStore(StorePath);
        CheatSet set = store.Import("a.pat", Sample, new[] { "Game.D88" });
        Assert.Same(set, store.SetFor(new string?[] { null, "game.d88" }));
        Assert.Null(store.SetFor(new string?[] { "other.d88" }));

        store.SetGroup(set, 1, true);
        var reloaded = new CheatStore(StorePath);
        CheatSet again = Assert.Single(reloaded.Sets);
        Assert.Equal(new[] { 1 }, again.EnabledGroups);
        Assert.Single(reloaded.EnabledCodes(again));
    }

    [Fact]
    public void Store_ImportMovesDisksOutOfOldSet_AndDropsEmptySets()
    {
        var store = new CheatStore(StorePath);
        store.Import("a.pat", Sample, new[] { "g.d88" });
        CheatSet b = store.Import("b.pat", Sample, new[] { "g.d88" });
        Assert.Same(b, Assert.Single(store.Sets));
    }

    [Fact]
    public void Store_FollowsPresetTextChanges_KeepingGroupsOfTheSameName()
    {
        var old = new CheatPreset { Title = "Game", Text = "#A\n0000C000 0001\n#B\n0000C001 0001\n" };
        var store = new CheatStore(StorePath);
        CheatSet set = store.Import(old.Title, old.Text, new[] { "g.d88" }, old.Title);
        store.SetGroup(set, 1, true);   // "B"

        var updated = new CheatPreset { Title = "Game", Text = "#C\n0000C002 0001\n#B\n0000C001 0002\n" };
        var reloaded = new CheatStore(StorePath, new[] { updated });
        CheatSet followed = Assert.Single(reloaded.Sets);
        Assert.Equal(updated.Text, followed.Text);
        Assert.Equal(new[] { 1 }, followed.EnabledGroups);   // "B" is now index 1 again
    }

    [Fact]
    public void Store_ReadsMacosStyleCamelCaseFile()
    {
        File.WriteAllText(StorePath,
            """{"sets":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"x.pat","text":"#A\n0000C000 0001\n","diskFiles":["g.d88"],"enabledGroups":[0]}]}""");
        var store = new CheatStore(StorePath);
        CheatSet set = Assert.Single(store.Sets);
        Assert.Equal("x.pat", set.Name);
        Assert.Single(store.EnabledCodes(set));
    }
}
