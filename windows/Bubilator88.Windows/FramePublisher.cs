using System;

namespace Bubilator88.Windows;

/// <summary>
/// One completed 640×400 RGBA frame plus the display metadata the presenter
/// needs to interpret it. <see cref="Is400Line"/> travels with the frame
/// because the presenter must not read live machine state, which belongs to
/// the emulation thread and may already describe a later frame. Mirrors the
/// macOS <c>FrameSlot</c>.
/// </summary>
internal sealed class FrameSlot
{
    public readonly byte[] Pixels;
    public bool Is400Line;

    public FrameSlot(int byteCount) => Pixels = new byte[byteCount];
}

/// <summary>
/// Hand-off of completed frames from the emulation thread to the UI thread
/// (mirrors the macOS <c>FramePublisher</c>).
///
/// <para>Three slots rotate between three roles: one being filled by the
/// producer, one holding the newest completed frame, one held by the consumer.
/// No slot is ever touched by two threads at once, so the lock only guards the
/// bookkeeping — never the pixel copy.</para>
///
/// <para>The producer never blocks: if the UI has not picked up the previous
/// frame, that frame is simply dropped. Emulation must not be paced by the
/// display.</para>
/// </summary>
internal sealed class FramePublisher
{
    private readonly object _lock = new();
    private readonly FrameSlot[] _free = new FrameSlot[3];
    private int _freeCount;
    private FrameSlot? _ready;       // newest completed frame, not yet picked up
    private FrameSlot? _consuming;   // held by the consumer until its next acquire
    private long _published;

    public FramePublisher(int byteCount)
    {
        for (int i = 0; i < _free.Length; i++) _free[i] = new FrameSlot(byteCount);
        _freeCount = _free.Length;
    }

    /// <summary>Frames published with <c>counted: true</c> since creation (FPS readout).</summary>
    public long PublishedCount
    {
        get { lock (_lock) return _published; }
    }

    /// <summary>
    /// Publish a completed frame (producer side). <paramref name="counted"/> is
    /// false for a frame rendered outside the loop (e.g. right after a state
    /// load) so it does not inflate the FPS readout.
    /// </summary>
    public void Publish(ReadOnlySpan<byte> pixels, bool is400Line, bool counted = true)
    {
        FrameSlot slot;
        lock (_lock)
        {
            if (_freeCount > 0)
            {
                slot = _free[--_freeCount];
            }
            else if (_ready is not null)
            {
                // The consumer is behind: overwrite the frame it has not
                // picked up rather than stalling emulation.
                slot = _ready;
                _ready = null;
            }
            else
            {
                return;
            }
        }

        pixels[..Math.Min(pixels.Length, slot.Pixels.Length)].CopyTo(slot.Pixels);
        slot.Is400Line = is400Line;

        lock (_lock)
        {
            if (_ready is not null) _free[_freeCount++] = _ready;
            _ready = slot;
            if (counted) _published++;
        }
    }

    /// <summary>
    /// Take the newest completed frame, or null if none arrived since the last
    /// call (consumer side). The slot stays valid until the next acquire.
    /// </summary>
    public FrameSlot? AcquireLatest()
    {
        lock (_lock)
        {
            if (_ready is not { } next) return null;
            _ready = null;
            if (_consuming is not null) _free[_freeCount++] = _consuming;
            _consuming = next;
            return next;
        }
    }
}
