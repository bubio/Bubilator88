using System;
using System.IO;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Tasks;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Bubilator88.Windows;

/// <summary>
/// Encodes the emulator's 640×400 RGBA8888 frame buffer to PNG — for screenshots
/// (full size) and save-state thumbnails (scaled to 320×200, matching the macOS
/// captureThumbnail). Uses the Windows.Graphics.Imaging encoder so there's no
/// System.Drawing/GDI+ dependency.
/// </summary>
internal static class ImageCodec
{
    /// <summary>
    /// Encode <paramref name="rgba"/> (w×h, 4 bytes/pixel) to a PNG byte array,
    /// optionally rescaling to <paramref name="outW"/>×<paramref name="outH"/>
    /// (0 = keep source size).
    /// </summary>
    public static async Task<byte[]> EncodePngAsync(byte[] rgba, int w, int h, int outW = 0, int outH = 0)
    {
        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(
            BitmapPixelFormat.Rgba8,
            BitmapAlphaMode.Premultiplied,
            (uint)w, (uint)h,
            96, 96,
            rgba);
        if (outW > 0 && outH > 0 && (outW != w || outH != h))
        {
            encoder.BitmapTransform.ScaledWidth = (uint)outW;
            encoder.BitmapTransform.ScaledHeight = (uint)outH;
            encoder.BitmapTransform.InterpolationMode = BitmapInterpolationMode.Linear;
        }
        await encoder.FlushAsync();

        stream.Seek(0);
        var bytes = new byte[stream.Size];
        await stream.ReadAsync(bytes.AsBuffer(), (uint)stream.Size, InputStreamOptions.None);
        return bytes;
    }

    /// <summary>Encode and write a PNG file (creating the parent directory).</summary>
    public static async Task WritePngAsync(byte[] rgba, int w, int h, string path, int outW = 0, int outH = 0)
    {
        byte[] png = await EncodePngAsync(rgba, w, h, outW, outH);
        string? dir = Path.GetDirectoryName(path);
        if (dir is not null) Directory.CreateDirectory(dir);
        await File.WriteAllBytesAsync(path, png);
    }
}
