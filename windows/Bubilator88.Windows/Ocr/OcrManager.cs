using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Tasks;
using Windows.Foundation;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;

namespace Bubilator88.Windows.Ocr;

/// <summary>
/// Drives the OCR-only text-detection overlay: periodically snapshots the
/// emulator's rendered pixel buffer, upscales/contrast-boosts it, runs
/// Windows.Media.Ocr, and publishes Japanese-text bounding boxes.
///
/// Mirrors macOS TranslationManager's cadence/debounce design (~3s timer,
/// pixel-hash skip, immediate-trigger override) but has no translation step —
/// that's a follow-up; this only detects and exposes boxes. Unlike
/// TranslationManager, results aren't pushed via a callback: the UI thread
/// polls <see cref="TryTakeResult"/> once per rendered frame, matching this
/// codebase's existing background-work idiom (see AiUpscaler's lock-guarded
/// double buffer / D3DScreen.TryGetAiInferenceCount poll).
/// </summary>
internal sealed class OcrManager
{
    private const double CaptureIntervalSeconds = 3.0;
    private const int HashSampleStride = 4000;

    private readonly OcrEngine? _engine;
    private readonly object _lock = new();

    private double _accum;
    private int _lastPixelHash;
    private volatile bool _busy;

    // Guarded by _lock. Non-null means a result is ready to be drained by
    // TryTakeResult; set by the background Pipeline (or directly by
    // Toggle(false)/Reset() to clear stale boxes) and cleared once taken.
    private List<OcrDetection>? _pendingResult;

    /// <summary>False when the Japanese OCR language pack isn't installed —
    /// TryCreateFromLanguage returned null. Toggle(true) is then a no-op.</summary>
    public bool EngineAvailable { get; }

    public bool Enabled { get; private set; }

    public OcrManager()
    {
        try
        {
            _engine = OcrEngine.TryCreateFromLanguage(new Language("ja"));
        }
        catch
        {
            _engine = null;
        }
        EngineAvailable = _engine is not null;
    }

    /// <summary>Enable/disable the overlay. Returns false without changing
    /// state if enabling was requested but the language pack isn't installed —
    /// the caller should surface that to the user (e.g. a toast).</summary>
    public bool Toggle(bool enabled)
    {
        if (enabled && !EngineAvailable) return false;
        Enabled = enabled;
        if (!enabled)
            lock (_lock) { _pendingResult = new List<OcrDetection>(); }
        return true;
    }

    /// <summary>Clear debounce/detection state so stale boxes don't linger and
    /// the next capture always runs. Call on machine reset / boot-mode / clock
    /// changes, whose new screen content makes the last hash/boxes stale.</summary>
    public void Reset()
    {
        _accum = 0;
        _lastPixelHash = 0;
        lock (_lock) { _pendingResult = new List<OcrDetection>(); }
    }

    /// <summary>Call once per rendered frame with the freshly-rendered pixel
    /// buffer. Accumulates wall-clock time and fires a background OCR pass
    /// roughly every 3 seconds (matches macOS's ~4Hz-timer/12 cadence),
    /// skipping the pass entirely if the sampled frame hash hasn't changed.</summary>
    public void Tick(double dt, ReadOnlySpan<byte> pixels)
    {
        if (!Enabled || _engine is null) return;
        _accum += dt;
        if (_accum < CaptureIntervalSeconds) return;
        _accum = 0;
        Capture(pixels);
    }

    /// <summary>Force a capture now, bypassing the cadence timer (the pixel-hash
    /// debounce still applies to avoid stacking redundant work on an unchanged
    /// frame). Call on first enable and whenever the emulator pauses, matching
    /// macOS's triggerImmediateOCR().</summary>
    public void TriggerImmediate(ReadOnlySpan<byte> pixels)
    {
        if (!Enabled || _engine is null) return;
        _lastPixelHash = 0; // force past the debounce below
        Capture(pixels);
    }

    private void Capture(ReadOnlySpan<byte> pixels)
    {
        if (_busy) return;

        int hash = 0;
        for (int i = 0; i < pixels.Length; i += HashSampleStride)
            hash = hash * 31 + pixels[i];
        if (hash == _lastPixelHash) return;
        _lastPixelHash = hash;

        byte[] copy = pixels.ToArray();
        _busy = true;
        _ = Task.Run(() => Pipeline(copy));
    }

    /// <summary>Drain the latest completed OCR pass, if one arrived since the
    /// last call. Poll once per frame from the UI thread.</summary>
    public bool TryTakeResult(out IReadOnlyList<OcrDetection> detections)
    {
        lock (_lock)
        {
            if (_pendingResult is null)
            {
                detections = Array.Empty<OcrDetection>();
                return false;
            }
            detections = _pendingResult;
            _pendingResult = null;
            return true;
        }
    }

    private async Task Pipeline(byte[] pixels)
    {
        try
        {
            byte[] scaled = ImagePreprocessor.Scale2x(pixels, EmulatorHost.ScreenWidth, EmulatorHost.ScreenHeight, out int w, out int h);
            scaled = ImagePreprocessor.Scale2x(scaled, w, h, out w, out h); // Scale4x total

            ImagePreprocessor.InvertAndSharpen(scaled, w, h);
            byte[] bgra = ImagePreprocessor.RgbaToBgra(scaled);

            var bitmap = new SoftwareBitmap(BitmapPixelFormat.Bgra8, w, h, BitmapAlphaMode.Straight);
            bitmap.CopyFromBuffer(bgra.AsBuffer());

            OcrResult result = await _engine!.RecognizeAsync(bitmap);

            var detections = new List<OcrDetection>();
            foreach (OcrLine line in result.Lines)
            {
                if (line.Words.Count == 0 || !OcrTypes.ContainsJapanese(line.Text)) continue;

                double minX = double.MaxValue, minY = double.MaxValue, maxX = double.MinValue, maxY = double.MinValue;
                foreach (OcrWord word in line.Words)
                {
                    var r = word.BoundingRect;
                    minX = Math.Min(minX, r.X);
                    minY = Math.Min(minY, r.Y);
                    maxX = Math.Max(maxX, r.X + r.Width);
                    maxY = Math.Max(maxY, r.Y + r.Height);
                }

                var normalized = new Rect(minX / w, minY / h, (maxX - minX) / w, (maxY - minY) / h);
                detections.Add(new OcrDetection(normalized, line.Text));
            }

            lock (_lock) { _pendingResult = detections; }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[OCR] pipeline failed: {ex}");
        }
        finally
        {
            _busy = false;
        }
    }

    /// <summary>Stop producing new results. Safe to call even while a
    /// background pipeline pass is in flight — it will still finish and store
    /// into _pendingResult, but Enabled=false means nothing will ever
    /// TryTakeResult it into a torn-down window's overlay.</summary>
    public void Dispose()
    {
        Enabled = false;
    }
}
