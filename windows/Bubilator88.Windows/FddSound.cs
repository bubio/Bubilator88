using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Vortice.Multimedia;
using Vortice.XAudio2;

namespace Bubilator88.Windows;

/// <summary>
/// Synthesized floppy disk drive access sounds — a C# port of the macOS
/// FDDSound.swift (Bubilator88/Audio/FDDSound.swift). Generates seek-step (head
/// movement) and read/write (head activity) sounds programmatically — no
/// external audio files needed — using a dedicated XAudio2 engine with one
/// source voice per drive, mirroring macOS's dedicated AVAudioEngine. This
/// engine is independent of the main YM2608 audio (<see cref="XAudioSink"/>)
/// so it can be routed to its own output device (<see cref="Start"/> /
/// <see cref="ApplyOutputDevice"/>), exactly like macOS's
/// `start(outputDeviceUID:)` / `applyOutputDeviceUID`. Stereo drive separation
/// is baked into the pre-rendered buffers (drive 0 = right-leaning, drive 1 =
/// left-leaning), matching the macOS gain table exactly.
/// </summary>
internal sealed unsafe class FddSound : IDisposable
{
    private const int SampleRate = 44100;
    private const int Channels = 2;

    private IXAudio2? _xaudio;
    private IXAudio2MasteringVoice? _master;
    /// Device ID most recently used with <see cref="Start"/> — reapplied by
    /// <see cref="ApplyOutputDevice"/> to restart the engine on the new device.
    private string _currentDeviceId = "";

    /// All per-drive state bundled together (buffers, pinned pointers, voice,
    /// throttle timestamp) so it can never fall out of sync across parallel
    /// arrays — everything one drive owns lives and dies together.
    private sealed class DriveState
    {
        public readonly IntPtr SeekPtr;
        public readonly int SeekFloatCount;
        public readonly IntPtr ReadPtr;
        public readonly int ReadFloatCount;
        private readonly GCHandle _seekHandle;
        private readonly GCHandle _readHandle;

        public IXAudio2SourceVoice? Voice;
        public double LastReadAccessTime;

        public DriveState(float[] seekStep, float[] readAccess)
        {
            _seekHandle = GCHandle.Alloc(seekStep, GCHandleType.Pinned);
            SeekPtr = _seekHandle.AddrOfPinnedObject();
            SeekFloatCount = seekStep.Length;

            _readHandle = GCHandle.Alloc(readAccess, GCHandleType.Pinned);
            ReadPtr = _readHandle.AddrOfPinnedObject();
            ReadFloatCount = readAccess.Length;
        }

        public void FreeBuffers()
        {
            if (_seekHandle.IsAllocated) _seekHandle.Free();
            if (_readHandle.IsAllocated) _readHandle.Free();
        }
    }

    private readonly DriveState[] _drives = new DriveState[2];

    /// L/R gain per drive: drive 0 leans right, drive 1 leans left (neither
    /// fully panned) — matches macOS FDDSound.driveGain exactly.
    private static readonly (float L, float R)[] DriveGain =
    {
        (0.3f, 0.8f),
        (0.8f, 0.3f),
    };

    public bool IsEnabled { get; private set; }

    private float _volume = 0.2f;

    /// <summary>Volume for FDD sounds (0.0-1.0).</summary>
    public float Volume
    {
        get => _volume;
        set
        {
            _volume = value;
            foreach (var drive in _drives)
                if (drive.Voice is { } voice) voice.Volume = value;
        }
    }

    /// <summary>Maps a 0/1/2 UI level to the actual gain (matches macOS FDDSound.volume(for:)).</summary>
    public static float VolumeForLevel(int level) => level switch
    {
        0 => 0.06f,   // 小: 30%
        1 => 0.12f,   // 中: 60%
        _ => 0.2f,    // 大: 100%
    };

    public FddSound()
    {
        var monoSeek = GenerateSeekStepMono();
        var monoRead = GenerateReadAccessMono();
        for (int i = 0; i < 2; i++)
        {
            _drives[i] = new DriveState(
                ApplyStereoPan(monoSeek, DriveGain[i]),
                ApplyStereoPan(monoRead, DriveGain[i]));
        }
    }

    private static float[] ApplyStereoPan(float[] mono, (float L, float R) gain)
    {
        var stereo = new float[mono.Length * 2];
        for (int i = 0; i < mono.Length; i++)
        {
            stereo[i * 2] = mono[i] * gain.L;
            stereo[i * 2 + 1] = mono[i] * gain.R;
        }
        return stereo;
    }

    /// Generate mono seek step samples (~12ms mechanical click).
    private static float[] GenerateSeekStepMono()
    {
        const double duration = 0.012;
        int frameCount = (int)(SampleRate * duration);
        var samples = new float[frameCount];
        uint rng = 12345;
        for (int i = 0; i < frameCount; i++)
        {
            double t = (double)i / SampleRate;
            double envelope = Math.Exp(-t / (duration * 0.4));
            double thump = Math.Sin(2.0 * Math.PI * 50.0 * t) * 0.5;
            rng = rng * 1103515245 + 12345;
            double noise = ((rng >> 16) / 32768.0 - 1.0) * 0.15;
            samples[i] = (float)(envelope * thump + envelope * envelope * noise);
        }
        return samples;
    }

    /// Generate mono read access samples (~15ms soft buzz).
    private static float[] GenerateReadAccessMono()
    {
        const double duration = 0.015;
        int frameCount = (int)(SampleRate * duration);
        var samples = new float[frameCount];
        uint rng = 67890;
        for (int i = 0; i < frameCount; i++)
        {
            double t = (double)i / SampleRate;
            double attack = Math.Min(1.0, t / 0.002);
            double decay = Math.Max(0.0, 1.0 - (t - 0.002) / (duration - 0.002));
            double envelope = attack * decay;
            double buzz = Math.Sin(2.0 * Math.PI * 200.0 * t) * 0.3;
            rng = rng * 1103515245 + 12345;
            double noise = ((rng >> 16) / 32768.0 - 1.0) * 0.15;
            samples[i] = (float)(envelope * (buzz + noise));
        }
        return samples;
    }

    /// <summary>
    /// Create a dedicated XAudio2 engine + mastering voice bound to
    /// <paramref name="outputDeviceId"/> ("" = system default, matching
    /// <see cref="AudioDeviceInfo.SystemDefault"/>), then the two per-drive
    /// source voices on it. Independent of <see cref="XAudioSink"/>'s engine —
    /// this is what lets FDD sound target a different physical output device
    /// than the main YM2608 audio, matching macOS's `FDDSound.start(outputDeviceUID:)`.
    /// </summary>
    public void Start(string outputDeviceId = "")
    {
        if (IsEnabled) return;
        try
        {
            var xaudio = XAudio2.XAudio2Create();
            var master = string.IsNullOrEmpty(outputDeviceId)
                ? xaudio.CreateMasteringVoice(0, 0)
                : xaudio.CreateMasteringVoice(0, 0, 0, outputDeviceId);
            var format = WaveFormat.CreateIeeeFloatWaveFormat(SampleRate, Channels);
            foreach (var drive in _drives)
            {
                var voice = xaudio.CreateSourceVoice(format, VoiceFlags.None);
                voice.Volume = _volume;
                voice.Start();
                drive.Voice = voice;
            }
            _xaudio = xaudio;
            _master = master;
            _currentDeviceId = outputDeviceId;
            IsEnabled = true;
        }
        catch
        {
            // FDD sound init failed (e.g. the selected device was unplugged) —
            // emulator runs without disk sounds. Matches macOS's silent
            // AVAudioEngine.start() failure handling.
            Stop();
        }
    }

    /// <summary>
    /// Switch the output device live — mirrors macOS's `applyOutputDeviceUID`,
    /// which stops and rebuilds the engine since a running AVAudioEngine/XAudio2
    /// engine can't have its output device swapped in place.
    /// </summary>
    public void ApplyOutputDevice(string outputDeviceId)
    {
        _currentDeviceId = outputDeviceId;
        if (!IsEnabled) return;
        Stop();
        Start(outputDeviceId);
    }

    public void Stop()
    {
        foreach (var drive in _drives)
        {
            if (drive.Voice is { } voice)
            {
                voice.Stop();
                voice.DestroyVoice();
                voice.Dispose();
                drive.Voice = null;
            }
        }
        _master?.Dispose();
        _master = null;
        _xaudio?.Dispose();
        _xaudio = null;
        IsEnabled = false;
    }

    /// Minimum interval between read access sounds per drive (seconds).
    private const double ReadAccessMinIntervalSeconds = 0.03;
    private readonly Stopwatch _clock = Stopwatch.StartNew();

    /// Play seek step sound (called once per sampled seek-step event).
    public void PlaySeekStep(int drive)
    {
        if (!IsEnabled || (uint)drive >= 2) return;
        var d = _drives[drive];
        if (d.Voice is not { } voice) return;
        SubmitBuffer(voice, d.SeekPtr, d.SeekFloatCount);
    }

    /// Play read/write access sound (called once per sampled disk-access event).
    public void PlayReadAccess(int drive)
    {
        if (!IsEnabled || (uint)drive >= 2) return;
        var d = _drives[drive];
        if (d.Voice is not { } voice) return;
        double now = _clock.Elapsed.TotalSeconds;
        if (now - d.LastReadAccessTime < ReadAccessMinIntervalSeconds) return;
        d.LastReadAccessTime = now;
        SubmitBuffer(voice, d.ReadPtr, d.ReadFloatCount);
    }

    private static void SubmitBuffer(IXAudio2SourceVoice voice, IntPtr dataPointer, int floatCount)
    {
        var buffer = new AudioBuffer
        {
            AudioBytes = (uint)(floatCount * sizeof(float)),
            AudioDataPointer = dataPointer,
            Flags = BufferFlags.None,
        };
        voice.SubmitSourceBuffer(buffer);
    }

    public void Dispose()
    {
        Stop();
        foreach (var drive in _drives) drive.FreeBuffers();
    }
}
