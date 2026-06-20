using System;
using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using Vortice.Multimedia;
using Vortice.XAudio2;

namespace Bubilator88.Windows;

/// <summary>
/// Minimal XAudio2 streaming sink for 44.1 kHz interleaved-stereo float32 —
/// the format the YM2608 core produces. XAudio2 references (does not copy)
/// submitted memory until playback ends, so we recycle a fixed pool of pinned
/// buffers via the BufferEnd callback. On pool exhaustion we drop the frame
/// (brief underrun) rather than block the render thread.
///
/// v1 is intentionally simple; the macOS adaptive-rate ring buffer
/// (Audio/AudioOutput.swift) is a later-phase port.
/// </summary>
internal sealed unsafe class XAudioSink : IDisposable
{
    private const int SampleRate = 44100;
    private const int Channels = 2;
    private const int PoolSize = 8;
    private const int SlotFloats = 4096 * Channels; // matches EmulatorHost.AudioMaxPairs

    private readonly IXAudio2 _xaudio;
    private readonly IXAudio2MasteringVoice _master;
    private readonly IXAudio2SourceVoice _source;

    private readonly float[][] _slots = new float[PoolSize][];
    private readonly GCHandle[] _handles = new GCHandle[PoolSize];
    private readonly IntPtr[] _pointers = new IntPtr[PoolSize];
    private readonly ConcurrentQueue<int> _free = new();

    public XAudioSink()
    {
        _xaudio = XAudio2.XAudio2Create();
        _master = _xaudio.CreateMasteringVoice(Channels, SampleRate);

        var format = WaveFormat.CreateIeeeFloatWaveFormat(SampleRate, Channels);
        _source = _xaudio.CreateSourceVoice(format);
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

    /// <summary>Submit <paramref name="floatCount"/> interleaved floats.</summary>
    public void Submit(float[] samples, int floatCount)
    {
        if (floatCount <= 0) return;
        if (!_free.TryDequeue(out int slot)) return; // pool empty → drop (underrun)

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
