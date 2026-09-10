using System;
using System.Reflection;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace Bubilator88.Windows;

/// <summary>
/// The About dialog — a content-level port of the macOS About window
/// (Bubilator88/Views/AboutView.swift). Same title, subtitle, version line,
/// credits list (with clickable links) and copyright line; laid out with
/// WinUI controls instead of SwiftUI ones.
/// </summary>
public sealed partial class MainWindow
{
    private readonly record struct Credit(string Category, string Title, string? Author, string? Url);

    private static readonly Credit[] AboutCredits =
    [
        new("FM Synthesis", "fmgen", "cisc", "http://retropc.net/cisc/sound/"),
        new("Reference", "QUASI88", "S.Fukunaga", "https://www.eonet.ne.jp/~showtime/quasi88/"),
        new("Reference", "common source code project", "Takeda Toshiya", "https://takeda-toshiya.my.coocan.jp/common/index.html"),
        new("Reference", "X88000", "Manuke", "https://quagma.sakura.ne.jp/manuke/x88000.html"),
        new("Technical Docs", "PC-8801についてのページ", "youkan", "http://www.maroon.dti.ne.jp/youkan/pc88/"),
        new("Technical Docs", "PC-8801 VRAM情報", null, "http://mydocuments.g2.xrea.com/html/p8/vraminfo.html"),
        new("Scaling", "xBRZ", "Zenju", "https://sourceforge.net/projects/xbrz/"),
        new("AI Upscale", "Real-ESRGAN x2 (Quality)", null, "https://github.com/xinntao/Real-ESRGAN"),
        new("AI Upscale", "SRVGGNet x2 (Fast/Balanced, self-distilled)", null, null),
        new("AI Coding", "Claude Code", "Anthropic", "https://claude.ai/code"),
    ];

    private async void OnAbout(object sender, RoutedEventArgs e)
    {
        var version = Assembly.GetExecutingAssembly().GetName().Version;
        var versionText = version is null ? "?" : $"{version.Major}.{version.Minor}.{version.Build}";

        var panel = new StackPanel { Spacing = 8, Width = 420 };

        panel.Children.Add(new TextBlock
        {
            Text = "Bubilator88",
            FontSize = 24,
            FontWeight = FontWeights.Bold,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        panel.Children.Add(new TextBlock
        {
            Text = "NEC PC-8801mkIISR Emulator for Windows",
            Opacity = 0.7,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        panel.Children.Add(new TextBlock
        {
            Text = $"Version {versionText}",
            FontSize = 12,
            Opacity = 0.5,
            HorizontalAlignment = HorizontalAlignment.Center,
        });

        panel.Children.Add(Divider());

        var creditsGrid = new Grid { ColumnSpacing = 12, RowSpacing = 8 };
        creditsGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        creditsGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (int i = 0; i < AboutCredits.Length; i++)
        {
            var credit = AboutCredits[i];

            var category = new TextBlock
            {
                Text = credit.Category,
                Opacity = 0.6,
                TextAlignment = TextAlignment.Right,
                HorizontalAlignment = HorizontalAlignment.Right,
            };
            Grid.SetRow(category, i);
            Grid.SetColumn(category, 0);

            var titleAuthor = new StackPanel { Spacing = 2 };
            if (credit.Url is not null)
            {
                var link = new HyperlinkButton
                {
                    Content = credit.Title,
                    Padding = new Thickness(0),
                    NavigateUri = new Uri(credit.Url),
                };
                titleAuthor.Children.Add(link);
            }
            else
            {
                titleAuthor.Children.Add(new TextBlock { Text = credit.Title });
            }
            if (credit.Author is not null)
            {
                titleAuthor.Children.Add(new TextBlock { Text = $"by {credit.Author}", FontSize = 11, Opacity = 0.5 });
            }
            Grid.SetRow(titleAuthor, i);
            Grid.SetColumn(titleAuthor, 1);

            creditsGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            creditsGrid.Children.Add(category);
            creditsGrid.Children.Add(titleAuthor);
        }
        panel.Children.Add(new ScrollViewer
        {
            Content = creditsGrid,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
            MaxHeight = 260,
        });

        panel.Children.Add(Divider());

        panel.Children.Add(new TextBlock
        {
            Text = "© 2026 bubio. Licensed under GPL v2.0",
            FontSize = 11,
            Opacity = 0.5,
            HorizontalAlignment = HorizontalAlignment.Center,
        });

        var dialog = new ContentDialog
        {
            Title = null,
            Content = panel,
            CloseButtonText = "OK",
            XamlRoot = Root.XamlRoot,
        };
        await ShowDialogAsync(dialog);
    }

    private static FrameworkElement Divider()
        => new Rectangle
        {
            Height = 1,
            Fill = new SolidColorBrush(Color.FromArgb(0x30, 0x80, 0x80, 0x80)),
            Margin = new Thickness(0, 4, 0, 4),
        };
}
