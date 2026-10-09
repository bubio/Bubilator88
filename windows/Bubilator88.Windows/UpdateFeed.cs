using System;
using System.Linq;
using System.Xml.Linq;

namespace Bubilator88.Windows;

/// <summary>
/// A Windows release version, parsed from a <c>win-v&lt;major&gt;.&lt;minor&gt;.&lt;patch&gt;</c>
/// tag. The release feed also carries the macOS app (<c>v1.5.0</c>) and AI model
/// archives (<c>models-v1</c>); neither matches, so they never count as a
/// Windows release.
/// </summary>
internal readonly record struct WinVersion(int Major, int Minor, int Patch) : IComparable<WinVersion>
{
    private const string TagPrefix = "win-v";

    /// <summary>Parses <c>win-v1.2.3</c>, or a bare <c>1.2.3</c> (the assembly version).</summary>
    public static WinVersion? Parse(string? s)
    {
        if (string.IsNullOrEmpty(s)) return null;
        string body = s.StartsWith(TagPrefix, StringComparison.Ordinal) ? s[TagPrefix.Length..] : s;
        string[] parts = body.Split('.');
        if (parts.Length != 3 || parts.Any(p => p.Length == 0 || !p.All(char.IsAsciiDigit))) return null;
        if (!int.TryParse(parts[0], out int major) || !int.TryParse(parts[1], out int minor)
            || !int.TryParse(parts[2], out int patch)) return null;
        return new WinVersion(major, minor, patch);
    }

    public int CompareTo(WinVersion o)
        => (Major, Minor, Patch).CompareTo((o.Major, o.Minor, o.Patch));

    public static bool operator <(WinVersion a, WinVersion b) => a.CompareTo(b) < 0;
    public static bool operator >(WinVersion a, WinVersion b) => a.CompareTo(b) > 0;
    public static bool operator <=(WinVersion a, WinVersion b) => a.CompareTo(b) <= 0;
    public static bool operator >=(WinVersion a, WinVersion b) => a.CompareTo(b) >= 0;

    public override string ToString() => $"{Major}.{Minor}.{Patch}";

    /// <summary>The tag as written in the release (<c>win-v1.2.3</c>).</summary>
    public string Tag => TagPrefix + this;
}

/// <summary>A Windows release found in the feed.</summary>
internal sealed record AvailableRelease(WinVersion Version, Uri Url);

/// <summary>
/// Reads GitHub's <c>releases.atom</c> and picks the newest Windows release.
/// The tag is taken from each entry's <c>alternate</c> link
/// (<c>…/releases/tag/&lt;tag&gt;</c>) rather than its title, which can be hand-written.
/// Entries are not in version order, so the newest is chosen by comparing versions.
/// </summary>
internal static class ReleaseFeed
{
    public static readonly Uri Url = new("https://github.com/bubio/Bubilator88/releases.atom");

    public static AvailableRelease? LatestRelease(string xml)
    {
        XDocument doc;
        try { doc = XDocument.Parse(xml); }
        catch (System.Xml.XmlException) { return null; }

        AvailableRelease? best = null;
        foreach (XElement entry in doc.Descendants().Where(e => e.Name.LocalName == "entry"))
        {
            foreach (XElement link in entry.Elements().Where(e => e.Name.LocalName == "link"))
            {
                if ((string?)link.Attribute("rel") != "alternate") continue;
                if (!Uri.TryCreate((string?)link.Attribute("href"), UriKind.Absolute, out Uri? url)) continue;
                string[] segments = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
                if (segments.Length < 2 || segments[^2] != "tag") continue;
                // Only win-v* tags: a bare 1.2.3 would parse, but the macOS tags carry a "v" prefix alone.
                if (!segments[^1].StartsWith("win-v", StringComparison.Ordinal)) continue;
                if (WinVersion.Parse(segments[^1]) is not { } version) continue;
                if (best is null || version > best.Version) best = new AvailableRelease(version, url);
            }
        }
        return best;
    }

    /// <summary>Whether the launch check should put up the dialog for <paramref name="latest"/>.</summary>
    public static bool ShouldNotify(WinVersion latest, WinVersion current,
                                    WinVersion? skipped, DateTime? remindAfter, DateTime now)
    {
        if (latest <= current) return false;
        if (skipped is { } s && latest <= s) return false;
        if (remindAfter is { } r && now < r) return false;
        return true;
    }
}
