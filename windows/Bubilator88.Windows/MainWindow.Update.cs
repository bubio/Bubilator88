using System;
using System.Net.Http;
using System.Reflection;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Bubilator88.Windows;

/// <summary>
/// Tells the user when a newer Windows release is on GitHub (port of the macOS
/// UpdateChecker). It only points at the release page; downloading and installing
/// stay with the user. The launch check runs at most once a day, stays silent on
/// any failure and honours "Remind Me Later" and "Skip This Version"; the Help
/// menu command ignores both and reports every outcome.
/// </summary>
public sealed partial class MainWindow
{
    private static readonly TimeSpan UpdateRemindInterval = TimeSpan.FromDays(3);
    private static readonly TimeSpan UpdateCheckInterval = TimeSpan.FromDays(1);
    private static readonly TimeSpan UpdateLaunchDelay = TimeSpan.FromSeconds(5);

    private bool _automaticUpdateCheck = true;
    private DateTime? _lastUpdateCheck;
    private DateTime? _updateRemindAfter;
    private string? _skippedUpdateVersion;   // as written in the release tag (win-v1.2.0)
    private bool _isCheckingForUpdate;

    private static WinVersion? CurrentVersion
    {
        get
        {
            Version? v = Assembly.GetExecutingAssembly().GetName().Version;
            return v is null ? null : new WinVersion(v.Major, v.Minor, Math.Max(v.Build, 0));
        }
    }

    /// <summary>The once-a-day check run at launch.</summary>
    private async void CheckForUpdateOnLaunch()
    {
        if (!_automaticUpdateCheck) return;
        if (_lastUpdateCheck is { } last && DateTime.UtcNow - last < UpdateCheckInterval) return;
        await Task.Delay(UpdateLaunchDelay);
        if (_isCheckingForUpdate || CurrentVersion is not { } current) return;
        _isCheckingForUpdate = true;
        try
        {
            AvailableRelease? latest;
            try { latest = await FetchLatestReleaseAsync(); }
            catch { return; }   // stay silent on any failure
            _lastUpdateCheck = DateTime.UtcNow;
            SaveSettings();
            if (latest is null || !ReleaseFeed.ShouldNotify(latest.Version, current,
                    WinVersion.Parse(_skippedUpdateVersion), _updateRemindAfter, DateTime.UtcNow))
                return;
            await PresentUpdateDialogAsync(latest, current);
        }
        finally { _isCheckingForUpdate = false; }
    }

    /// <summary>"Check for Updates…" from the Help menu.</summary>
    private async void OnCheckForUpdates(object sender, RoutedEventArgs e)
    {
        if (_isCheckingForUpdate || CurrentVersion is not { } current) return;
        _isCheckingForUpdate = true;
        try
        {
            try
            {
                AvailableRelease? latest = await FetchLatestReleaseAsync();
                if (latest is not null && latest.Version > current)
                {
                    await PresentUpdateDialogAsync(latest, current);
                    return;
                }
                await ShowDialogAsync(new ContentDialog
                {
                    Title = "You're up to date.",
                    Content = $"Bubilator88 {current} is the latest version.",
                    CloseButtonText = "OK",
                    XamlRoot = Root.XamlRoot,
                });
            }
            catch (Exception ex)
            {
                await ShowDialogAsync(new ContentDialog
                {
                    Title = "Couldn't check for updates.",
                    Content = ex.Message,
                    CloseButtonText = "OK",
                    XamlRoot = Root.XamlRoot,
                });
            }
        }
        finally { _isCheckingForUpdate = false; }
    }

    private static async Task<AvailableRelease?> FetchLatestReleaseAsync()
    {
        using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Bubilator88-Windows");
        string xml = await client.GetStringAsync(ReleaseFeed.Url);
        return ReleaseFeed.LatestRelease(xml);
    }

    private async Task PresentUpdateDialogAsync(AvailableRelease release, WinVersion current)
    {
        var dialog = new ContentDialog
        {
            Title = $"Bubilator88 {release.Version} is available.",
            Content = $"You have {current}. Open the release page to download it.",
            PrimaryButtonText = "Download",
            SecondaryButtonText = "Remind Me Later",
            CloseButtonText = "Skip This Version",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Root.XamlRoot,
        };
        switch (await ShowDialogAsync(dialog))
        {
            case ContentDialogResult.Primary:
                await global::Windows.System.Launcher.LaunchUriAsync(release.Url);
                break;
            case ContentDialogResult.Secondary:
                _updateRemindAfter = DateTime.UtcNow + UpdateRemindInterval;
                SaveSettings();
                break;
            case ContentDialogResult.None:
                _skippedUpdateVersion = release.Version.Tag;
                SaveSettings();
                break;
        }
    }
}
