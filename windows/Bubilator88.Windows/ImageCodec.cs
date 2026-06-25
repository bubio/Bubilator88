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
    /// Encoder id, file extension and save-picker label for a screenshot format
    /// key ("png" / "jpeg" / "heic"), mirroring the macOS Settings screenshot
    /// formats. Unknown keys fall back to PNG.
    /// </summary>
    public static (Guid EncoderId, string Extension, string Label) FormatInfo(string format)
        => format switch
        {
            "jpeg" => (BitmapEncoder.JpegEncoderId, ".jpg", "JPEG Image"),
            "heic" => (BitmapEncoder.HeifEncoderId, ".heic", "HEIC Image"),
            _ => (BitmapEncoder.PngEncoderId, ".png", "PNG Image"),
        };

    /// <summary>
    /// Encode <paramref name="rgba"/> (w×h, 4 bytes/pixel) to a PNG byte array,
    /// optionally rescaling to <paramref name="outW"/>×<paramref name="outH"/>
    /// (0 = keep source size).
    /// </summary>
    public static Task<byte[]> EncodePngAsync(byte[] rgba, int w, int h, int outW = 0, int outH = 0)
        => EncodeAsync(rgba, w, h, "png", outW, outH);

    /// <summary>
    /// Encode <paramref name="rgba"/> (w×h, 4 bytes/pixel) to the given screenshot
    /// <paramref name="format"/> ("png" / "jpeg" / "heic"), optionally rescaling to
    /// <paramref name="outW"/>×<paramref name="outH"/> (0 = keep source size).
    /// JPEG/HEIC are opaque (alpha ignored); PNG keeps premultiplied alpha.
    /// </summary>
    public static async Task<byte[]> EncodeAsync(byte[] rgba, int w, int h, string format, int outW = 0, int outH = 0)
    {
        var (encoderId, _, _) = FormatInfo(format);
        bool isPng = encoderId == BitmapEncoder.PngEncoderId;

        using var stream = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(encoderId, stream);
        encoder.SetPixelData(
            BitmapPixelFormat.Rgba8,
            isPng ? BitmapAlphaMode.Premultiplied : BitmapAlphaMode.Ignore,
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
