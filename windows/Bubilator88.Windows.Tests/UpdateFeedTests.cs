using System;
using Xunit;

namespace Bubilator88.Windows.Tests;

public class UpdateFeedTests
{
    // Entries are not in version order, and the macOS app and AI model
    // releases share the feed.
    private const string Feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xml:lang="en-US">
          <link type="text/html" rel="alternate" href="https://github.com/bubio/Bubilator88/releases"/>
          <entry>
            <link rel="alternate" type="text/html" href="https://github.com/bubio/Bubilator88/releases/tag/v1.5.0"/>
            <title>v1.5.0</title>
          </entry>
          <entry>
            <link rel="alternate" type="text/html" href="https://github.com/bubio/Bubilator88/releases/tag/win-v1.0.0"/>
            <title>win-v1.0.0 — First Windows release</title>
          </entry>
          <entry>
            <link rel="alternate" type="text/html" href="https://github.com/bubio/Bubilator88/releases/tag/win-v1.10.0"/>
            <title>win-v1.10.0</title>
          </entry>
          <entry>
            <link rel="alternate" type="text/html" href="https://github.com/bubio/Bubilator88/releases/tag/models-v1"/>
            <title>AI models v1</title>
          </entry>
          <entry>
            <link rel="alternate" type="text/html" href="https://github.com/bubio/Bubilator88/releases/tag/win-v1.9.9"/>
            <title>win-v1.9.9</title>
          </entry>
        </feed>
        """;

    private static WinVersion V(string s) => WinVersion.Parse(s)!.Value;

    [Fact]
    public void Versions_CompareNumerically()
    {
        Assert.True(V("win-v1.10.0") > V("win-v1.9.9"));
        Assert.True(V("2.0.0") > V("1.99.99"));
        Assert.Equal(V("win-v1.1.0"), V("1.1.0"));
    }

    [Theory]
    [InlineData("v1.5.0")]      // macOS tag
    [InlineData("models-v1")]
    [InlineData("win-v1.5")]
    [InlineData("win-v1.5.0-beta")]
    [InlineData("win-v1.5.0.1")]
    [InlineData("win-v1..0")]
    [InlineData("")]
    public void Parse_RejectsOtherTags(string tag)
        => Assert.Null(WinVersion.Parse(tag));

    [Fact]
    public void LatestRelease_PicksNewestWindowsTag()
    {
        var release = ReleaseFeed.LatestRelease(Feed);
        Assert.NotNull(release);
        Assert.Equal(V("1.10.0"), release!.Version);
        Assert.Equal("https://github.com/bubio/Bubilator88/releases/tag/win-v1.10.0", release.Url.AbsoluteUri);
    }

    [Fact]
    public void LatestRelease_NoWindowsTag_ReturnsNull()
        => Assert.Null(ReleaseFeed.LatestRelease(
            """<feed xmlns="http://www.w3.org/2005/Atom"><entry><link rel="alternate" href="https://github.com/bubio/Bubilator88/releases/tag/v1.5.0"/></entry></feed>"""));

    [Fact]
    public void LatestRelease_BrokenXml_ReturnsNull()
        => Assert.Null(ReleaseFeed.LatestRelease("<feed><entry>"));

    [Fact]
    public void ShouldNotify_OnlyForNewerVersion()
    {
        Assert.True(ReleaseFeed.ShouldNotify(V("1.2.0"), V("1.1.0"), null, null, DateTime.UtcNow));
        Assert.False(ReleaseFeed.ShouldNotify(V("1.1.0"), V("1.1.0"), null, null, DateTime.UtcNow));
    }

    [Fact]
    public void ShouldNotify_SkippedVersionStaysQuietUntilNewerOne()
    {
        Assert.False(ReleaseFeed.ShouldNotify(V("1.2.0"), V("1.1.0"), V("1.2.0"), null, DateTime.UtcNow));
        Assert.True(ReleaseFeed.ShouldNotify(V("1.3.0"), V("1.1.0"), V("1.2.0"), null, DateTime.UtcNow));
    }

    [Fact]
    public void ShouldNotify_RemindLaterUntilDeadline()
    {
        var now = new DateTime(2026, 10, 1, 0, 0, 0, DateTimeKind.Utc);
        Assert.False(ReleaseFeed.ShouldNotify(V("1.2.0"), V("1.1.0"), null, now.AddSeconds(1), now));
        Assert.True(ReleaseFeed.ShouldNotify(V("1.2.0"), V("1.1.0"), null, now, now));
    }
}
