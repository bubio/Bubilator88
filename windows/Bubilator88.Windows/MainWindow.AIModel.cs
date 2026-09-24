using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Bubilator88.Windows;

public sealed partial class MainWindow
{
    private Border? _aiDownloadPanel;
    private CancellationTokenSource? _aiDownloadCancellation;
    private Task? _aiDownloadTask;
    private bool _aiResumeAfterwards;

    /// <summary>Offer the missing model over the screen. The menu and emulator
    /// remain usable while the transfer is in progress.</summary>
    private void ShowQualityModelPanel()
    {
        if (_aiDownloadPanel is not null || _dialogOpen) return;
        _aiResumeAfterwards = !_paused;
        if (_aiResumeAfterwards) OnPauseResume(this, EmptyArgs);

        var model = AIModelStore.Quality;
        var status = new TextBlock
        {
            Text = $"Download Real-ESRGAN x2 ({model.ByteCount / 1_000_000} MB) for the Quality filter?",
            TextWrapping = TextWrapping.Wrap,
        };
        var progress = new ProgressBar
        {
            Minimum = 0, Maximum = model.ByteCount, Visibility = Visibility.Collapsed,
        };
        var action = new Button { Content = "Download" };
        var cancel = new Button { Content = "Cancel" };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(action);
        buttons.Children.Add(cancel);
        var body = new StackPanel { Spacing = 12 };
        body.Children.Add(new TextBlock { Text = "Quality AI model", FontSize = 18 });
        body.Children.Add(status);
        body.Children.Add(progress);
        body.Children.Add(buttons);
        var panel = new Border
        {
            Child = body,
            Width = 360,
            Padding = new Thickness(16),
            Margin = new Thickness(12),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Background = new SolidColorBrush(ColorHelper.FromArgb(245, 35, 35, 35)),
            BorderBrush = new SolidColorBrush(Colors.Gray),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
        };
        Grid.SetRow(panel, 1);
        Root.Children.Add(panel);
        _aiDownloadPanel = panel;

        action.Click += (_, _) =>
        {
            if (_aiDownloadTask is { IsCompleted: false }) return;
            action.IsEnabled = false;
            action.Visibility = Visibility.Collapsed;
            progress.Visibility = Visibility.Visible;
            progress.Value = 0;
            status.Text = "Downloading…";
            _aiDownloadCancellation?.Dispose();
            _aiDownloadCancellation = new CancellationTokenSource();
            _aiDownloadTask = DownloadQualityModelAsync(model, status, progress, action,
                _aiDownloadCancellation.Token);
        };
        cancel.Click += async (_, _) =>
        {
            cancel.IsEnabled = false;
            _aiDownloadCancellation?.Cancel();
            if (_aiDownloadTask is not null) await _aiDownloadTask;
            CloseQualityModelPanel();
        };
    }

    private async Task DownloadQualityModelAsync(DownloadableAIModel model, TextBlock status,
        ProgressBar progress, Button action, CancellationToken token)
    {
        try
        {
            using var client = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            var reporter = new Progress<long>(bytes =>
            {
                progress.Value = bytes;
                status.Text = $"Downloaded {bytes / 1_000_000.0:0.0} / {model.ByteCount / 1_000_000.0:0.0} MB";
            });
            await AIModelStore.Shared.DownloadAsync(model, client, reporter, token);
            if (token.IsCancellationRequested || _aiDownloadPanel is null) return;
            _videoFilter = "AIQuality";
            SaveSettings();
            SyncVideoFilterMenu();
            ApplyVideoFilter();
            CloseQualityModelPanel();
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception ex)
        {
            status.Text = $"Download failed: {ex.Message}";
            action.Content = "Retry";
            action.IsEnabled = true;
            action.Visibility = Visibility.Visible;
            progress.Visibility = Visibility.Collapsed;
        }
    }

    private void CloseQualityModelPanel()
    {
        if (_aiDownloadPanel is null) return;
        Root.Children.Remove(_aiDownloadPanel);
        _aiDownloadPanel = null;
        _aiDownloadCancellation?.Dispose();
        _aiDownloadCancellation = null;
        _aiDownloadTask = null;
        if (_aiResumeAfterwards && _paused) OnPauseResume(this, EmptyArgs);
        _aiResumeAfterwards = false;
        SyncVideoFilterMenu();
        RestoreEmulatorFocus();
    }
}
