using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace Bubilator88.Windows;

/// <summary>
/// ONNX Runtime (DirectML) AI super-resolution upscaler for the emulator display.
/// Windows port of the macOS <c>AIUpscaler.swift</c> (which uses CoreML): runs the
/// same Real-ESRGAN x2 weights to upscale 640×400 → 1280×800. Inference runs
/// asynchronously on a background thread with double-buffered output, so the 60 Hz
/// render loop never blocks — the latest completed frame is shown and the renderer
/// falls back to Bicubic until the first inference lands (matching macOS).
///
/// <para>The ONNX graph is the raw RRDBNet: input and output are float[0,1] RGB CHW
/// tensors (shapes [1,3,400,640] / [1,3,800,1280]). Normalization (/255) and the
/// float→RGBA8 conversion are done here, mirroring the macOS MultiArray path.</para>
/// </summary>
internal sealed class AiUpscaler : IDisposable
{
    internal enum State { Unavailable, Loading, Ready, Error }

    // Fixed I/O shapes (we always feed the full 640×400 frame, even in 200-line
    // mode — matching macOS). Output is exactly 2× per the x2 model.
    private const int InW = 640, InH = 400;
    private const int OutW = 1280, OutH = 800;
    private const int InputElems = 3 * InH * InW;

    private readonly string _modelName;
    private readonly object _lock = new();

    private InferenceSession? _session;
    private DenseTensor<float>? _inputTensor;       // reused [1,3,400,640]
    private byte[] _inputScratch = new byte[InW * InH * 4];   // RGBA copy for the worker

    // Double-buffered RGBA8 output: the worker writes one, the UI thread reads the
    // other. `_completed` is the version stamp the renderer uses to skip re-uploads.
    private readonly byte[][] _output = { new byte[OutW * OutH * 4], new byte[OutW * OutH * 4] };
    private int _readIndex;
    private bool _hasFrame;
    private bool _inferring;
    private int _generation;                         // bumped on Reset to drop stale results
    private long _completed;
    private int _loadStarted;                        // 0/1 guard for EnsureLoaded

    public State CurrentState { get; private set; } = State.Unavailable;
    public int OutputWidth => OutW;
    public int OutputHeight => OutH;

    /// <summary>Total inferences completed over this upscaler's lifetime. Monotonic
    /// — never reset (matching macOS <c>AIUpscaler.completedCount</c>), so the render
    /// loop can measure AI throughput as the delta over a sampling window. Frozen
    /// while the AI filter is inactive because <see cref="Submit"/> isn't called.</summary>
    public long CompletedCount { get { lock (_lock) return _completed; } }

    public AiUpscaler(string modelName = "RealESRGAN_x2")
    {
        _modelName = modelName;
    }

    /// <summary>
    /// Kick off model loading once (idempotent, non-blocking). Searches the user
    /// override folder first, then the app directory (bundled), mirroring macOS.
    /// On any failure the upscaler stays <see cref="State.Unavailable"/> so the
    /// renderer keeps using the Bicubic fallback — it never throws to the caller.
    /// </summary>
    public void EnsureLoaded()
    {
        if (Interlocked.Exchange(ref _loadStarted, 1) != 0) return;
        CurrentState = State.Loading;
        Task.Run(LoadModel);
    }

    private string? FindModel()
    {
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string[] candidates =
        {
            Path.Combine(local, "Bubilator88", "Models", _modelName + ".onnx"),
            Path.Combine(AppContext.BaseDirectory, _modelName + ".onnx"),
        };
        foreach (var c in candidates)
            if (File.Exists(c)) return c;
        return null;
    }

    private void LoadModel()
    {
        try
        {
            string? path = FindModel();
            if (path is null)
            {
                CurrentState = State.Unavailable;
                return;
            }

            var opts = new SessionOptions();
            // DirectML does not support memory-pattern optimization or parallel
            // execution; both must be off or session creation throws.
            opts.EnableMemoryPattern = false;
            opts.ExecutionMode = ExecutionMode.ORT_SEQUENTIAL;
            opts.AppendExecutionProvider_DML(0);

            var session = new InferenceSession(path, opts);
            lock (_lock)
            {
                _session = session;
                _inputTensor = new DenseTensor<float>(new[] { 1, 3, InH, InW });
                CurrentState = State.Ready;
            }
        }
        catch (Exception)
        {
            // DirectML unavailable (e.g. arm64 native missing) or a corrupt model:
            // degrade gracefully to the Bicubic fallback.
            CurrentState = State.Unavailable;
        }
    }

    /// <summary>
    /// Submit a 640×400 RGBA frame for upscaling. Non-blocking: copies the pixels
    /// and runs inference on a background thread. Drops the frame if a previous
    /// inference is still running (matches macOS isInferring guard).
    /// </summary>
    public void Submit(ReadOnlySpan<byte> rgba, int width, int height)
    {
        if (CurrentState != State.Ready) return;
        if (width != InW || height != InH || rgba.Length < InW * InH * 4) return;

        int gen;
        lock (_lock)
        {
            if (_inferring) return;
            _inferring = true;
            gen = _generation;
        }

        rgba.Slice(0, InW * InH * 4).CopyTo(_inputScratch);
        Task.Run(() => RunInference(gen));
    }

    private void RunInference(int generation)
    {
        try
        {
            InferenceSession? session;
            DenseTensor<float>? input;
            lock (_lock)
            {
                session = _session;
                input = _inputTensor;
            }
            if (session is null || input is null) { ClearInferring(); return; }

            // RGBA8 → CHW float[0,1] RGB (planar). No BGR swap: the ONNX graph
            // takes RGB directly (the macOS BGRA swizzle is a CoreML image quirk).
            Span<float> dst = input.Buffer.Span;
            const int plane = InH * InW;
            byte[] src = _inputScratch;
            for (int i = 0, p = 0; i < plane; i++, p += 4)
            {
                dst[i] = src[p] * (1f / 255f);                 // R plane
                dst[plane + i] = src[p + 1] * (1f / 255f);     // G plane
                dst[2 * plane + i] = src[p + 2] * (1f / 255f); // B plane
            }

            var inputs = new[] { NamedOnnxValue.CreateFromTensor("input", input) };
            using var results = session.Run(inputs);

            // Discard if Reset() ran during inference (stale generation).
            lock (_lock)
            {
                if (_generation != generation) { _inferring = false; return; }
            }

            // ORT returns a DenseTensor for float tensor outputs; read its buffer
            // directly (CHW planar). Bail if it's some non-dense layout.
            if (results[0].AsTensor<float>() is not DenseTensor<float> dense)
            {
                ClearInferring();
                return;
            }
            ReadOnlySpan<float> o = dense.Buffer.Span;

            int writeIndex = 1 - _readIndex;
            byte[] outBuf = _output[writeIndex];
            const int oplane = OutH * OutW;
            for (int i = 0, q = 0; i < oplane; i++, q += 4)
            {
                outBuf[q] = ToByte(o[i]);                  // R
                outBuf[q + 1] = ToByte(o[oplane + i]);     // G
                outBuf[q + 2] = ToByte(o[2 * oplane + i]); // B
                outBuf[q + 3] = 255;                       // A
            }

            lock (_lock)
            {
                if (_generation != generation) { _inferring = false; return; }
                _readIndex = writeIndex;
                _hasFrame = true;
                _completed++;
                _inferring = false;
            }
        }
        catch (Exception)
        {
            ClearInferring();
        }
    }

    private static byte ToByte(float v)
    {
        int n = (int)(v * 255f + 0.5f);
        if (n < 0) n = 0; else if (n > 255) n = 255;
        return (byte)n;
    }

    private void ClearInferring()
    {
        lock (_lock) { _inferring = false; }
    }

    /// <summary>
    /// Get the most recently completed 1280×800 RGBA output. Returns false until
    /// the first inference lands. <paramref name="version"/> increments per
    /// completed frame so the caller can skip re-uploading an unchanged result.
    /// </summary>
    public bool TryGetLatest(out byte[] rgba, out int width, out int height, out long version)
    {
        lock (_lock)
        {
            if (!_hasFrame)
            {
                rgba = Array.Empty<byte>(); width = height = 0; version = 0;
                return false;
            }
            rgba = _output[_readIndex];
            width = OutW; height = OutH; version = _completed;
            return true;
        }
    }

    /// <summary>Drop pending/completed output (keeps the loaded session) when the
    /// AI filter is deselected. Bumps the generation so in-flight inference is
    /// discarded instead of surfacing a stale frame on re-entry. <c>_completed</c>
    /// is intentionally NOT reset — it stays monotonic so <see cref="CompletedCount"/>
    /// throughput sampling survives filter switches (matching macOS).</summary>
    public void Reset()
    {
        lock (_lock)
        {
            _generation++;
            _hasFrame = false;
            _inferring = false;
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _session?.Dispose();
            _session = null;
            _inputTensor = null;
        }
    }
}
