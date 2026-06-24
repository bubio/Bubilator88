using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Vortice.Multimedia;
using Vortice.XAudio2;

namespace Bubilator88.Windows;

/// <summary>
/// XAudio2 streaming sink for 44.1 kHz interleaved-stereo float32 — the format
/// the YM2608 core produces. Each frame's drained samples are submitted as one
/// source-voice buffer; XAudio2 references (does not copy) the memory until
/// playback ends, so we recycle a fixed pool of pinned buffers via the
/// BufferEnd callback.
///
/// <para>Stability comes from <see cref="QueuedPairs"/>: the caller feeds it to
/// the core's adaptive rate control each frame so the producer (60 Hz frame
/// loop) and consumer (44.1 kHz device) don't drift. The pool is sized well
/// above the steady-state queue depth, so submissions are never dropped in
/// normal operation.</para>
/// </summary>
internal sealed unsafe class XAudioSink : IDisposable
{
    private const int SampleRate = 44100;
    private const int Channels = 2;
    private const int PoolSize = 24;
    private const int SlotFloats = 4096 * Channels; // matches EmulatorHost.AudioMaxPairs
    private const float MaxFreqRatio = 16.0f;        // top fast-forward multiplier (x16)

    private readonly IXAudio2 _xaudio;
    private readonly IXAudio2MasteringVoice _master;
    private readonly IXAudio2SourceVoice _source;

    private readonly float[][] _slots = new float[PoolSize][];
    private readonly GCHandle[] _handles = new GCHandle[PoolSize];
    private readonly IntPtr[] _pointers = new IntPtr[PoolSize];
    private readonly ConcurrentQueue<int> _free = new();

    // Total stereo frames ever submitted; compared against SamplesPlayed to
    // derive the queued (not-yet-played) latency.
    private long _submittedFrames;

    public XAudioSink()
    {
        _xaudio = XAudio2.XAudio2Create();
        // Follow the Windows default output device: pass 0/0 so the mastering
        // voice adopts the device's native channel count and sample rate
        // (deviceId == null also means it tracks default-device changes).
        // Forcing 44.1 kHz/stereo here makes XAudio2 produce silence on devices
        // whose mix format differs (e.g. 48 kHz). The source voice stays at
        // 44.1 kHz stereo (the YM2608 format) and XAudio2 sample-rate-converts.
        _master = _xaudio.CreateMasteringVoice(0, 0);
        _master.Volume = 0.6f;

        var format = WaveFormat.CreateIeeeFloatWaveFormat(SampleRate, Channels);
        // MaxFrequencyRatio caps SetFrequencyRatio; raise it to the top CPU-speed
        // multiplier (x16) so fast-forward can play the over-produced samples back
        // at up to 16× (sped-up audio), matching the macOS varispeed behavior.
        _source = _xaudio.CreateSourceVoice(format, VoiceFlags.None, MaxFreqRatio,
                                            enableCallbackEvents: true);
        _source.BufferEnd += OnBufferEnd;

        for (int i = 0; i < PoolSize; i++)
        {
            _slots[i] = new float[SlotFloats];
            _handles[i] = GCHandle.Alloc(_slots[i], GCHandleType.Pinned);
            _pointers[i] = _handles[i].AddrOfPinnedObject();
            _free.Enqueue(i);
        }

        _source.Start();
    }

    private void OnBufferEnd(IntPtr context) => _free.Enqueue(context.ToInt32());

    /// <summary>
    /// Stereo pairs submitted to XAudio2 but not yet played — i.e. the current
    /// output-buffer fill / latency. Drives the core's adaptive rate control.
    /// </summary>
    public int QueuedPairs
    {
        get
        {
            long queued = _submittedFrames - (long)_source.State.SamplesPlayed;
            return queued < 0 ? 0 : (int)queued;
        }
    }

    /// <summary>Master output volume (0.0–1.0).</summary>
    public void SetVolume(float volume) => _master.Volume = Math.Clamp(volume, 0f, 1f);

    /// <summary>
    /// Playback-rate multiplier for CPU fast-forward. At speed N the core
    /// produces N× the samples per wall-second; a ratio of N plays them back in
    /// real time (sped up / higher pitch), keeping audio in step with video.
    /// </summary>
    public void SetFrequencyRatio(float ratio)
        => _source.SetFrequencyRatio(Math.Clamp(ratio, 1f / 1024f, MaxFreqRatio), 0);

    /// <summary>Submit <paramref name="floatCount"/> interleaved floats.</summary>
    public void Submit(float[] samples, int floatCount)
    {
        if (floatCount <= 0) return;
        if (!_free.TryDequeue(out int slot)) return; // pool empty → drop (rare; rate control keeps depth low)

        floatCount = Math.Min(floatCount, SlotFloats);
        Array.Copy(samples, _slots[slot], floatCount);

        var buffer = new AudioBuffer
        {
            AudioBytes = (uint)(floatCount * sizeof(float)),
            AudioDataPointer = _pointers[slot],
            Flags = BufferFlags.None,
            Context = new IntPtr(slot),
        };
        _source.SubmitSourceBuffer(buffer);
        _submittedFrames += floatCount / Channels;
    }

    public void Dispose()
    {
        _source.Stop();
        _source.BufferEnd -= OnBufferEnd;
        _source.DestroyVoice();
        _source.Dispose();
        _master.Dispose();
        _xaudio.Dispose();
        foreach (var h in _handles)
            if (h.IsAllocated) h.Free();
    }
}
