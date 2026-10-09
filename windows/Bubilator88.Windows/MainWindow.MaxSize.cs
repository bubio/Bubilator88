using System;
using System.Runtime.InteropServices;
using WinRT.Interop;

namespace Bubilator88.Windows;

public sealed partial class MainWindow
{
    private const uint WmGetMinMaxInfo = 0x0024;
    private const int MaxWindowExtent = 16384;

    private delegate IntPtr SubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam,
                                         UIntPtr id, UIntPtr refData);

    // Held in a field: the native side keeps only the function pointer.
    private SubclassProc? _maxSizeSubclass;

    [DllImport("comctl32.dll")]
    private static extern bool SetWindowSubclass(IntPtr hwnd, SubclassProc proc, UIntPtr id, UIntPtr refData);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct MinMaxInfo
    {
        public int ReservedX, ReservedY;
        public int MaxSizeX, MaxSizeY;
        public int MaxPositionX, MaxPositionY;
        public int MinTrackX, MinTrackY;
        public int MaxTrackX, MaxTrackY;
    }

    /// <summary>
    /// Let the window grow past the display, as the macOS window does at ×4 on a
    /// small screen (the part that does not fit is simply off-screen). Windows
    /// otherwise clamps a window to the screen size plus its borders, which
    /// letterboxes the 8:5 screen with side margins.
    /// </summary>
    private void AllowOversizeWindow()
    {
        _maxSizeSubclass = (hwnd, msg, wParam, lParam, id, refData) =>
        {
            if (msg == WmGetMinMaxInfo)
            {
                var info = Marshal.PtrToStructure<MinMaxInfo>(lParam);
                info.MaxSizeX = info.MaxTrackX = MaxWindowExtent;
                info.MaxSizeY = info.MaxTrackY = MaxWindowExtent;
                Marshal.StructureToPtr(info, lParam, false);
                return IntPtr.Zero;
            }
            return DefSubclassProc(hwnd, msg, wParam, lParam);
        };
        SetWindowSubclass(WindowNative.GetWindowHandle(this), _maxSizeSubclass, UIntPtr.Zero, UIntPtr.Zero);
    }
}
