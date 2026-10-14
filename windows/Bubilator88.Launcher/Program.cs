using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace Bubilator88.Launcher;

/// <summary>
/// Starts <c>app\Bubilator88.exe</c> next to this launcher, forwarding the
/// command line, and exits. The app runs from its own folder, as it does when
/// started directly.
/// </summary>
internal static class Program
{
    private const string AppFolder = "app";
    private const string AppExe = "Bubilator88.exe";

    [STAThread]
    private static int Main(string[] args)
    {
        string appDir = Path.Combine(AppContext.BaseDirectory, AppFolder);
        string exePath = Path.Combine(appDir, AppExe);
        if (!File.Exists(exePath))
        {
            ShowError($"{exePath} was not found.\n\nKeep the {AppFolder} folder next to {AppExe} when moving Bubilator88.");
            return 1;
        }

        var psi = new ProcessStartInfo(exePath) { WorkingDirectory = appDir, UseShellExecute = false };
        foreach (string arg in args) psi.ArgumentList.Add(arg);
        try
        {
            using Process? _ = Process.Start(psi);
            return 0;
        }
        catch (Win32Exception ex)
        {
            ShowError($"Couldn't start {exePath}.\n\n{ex.Message}");
            return 1;
        }
    }

    private static void ShowError(string message)
        => MessageBoxW(IntPtr.Zero, message, "Bubilator88", MbIconError);

    private const uint MbIconError = 0x10;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);
}
