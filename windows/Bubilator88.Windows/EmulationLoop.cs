using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Bubilator88.Windows;

/// <summary>
/// The emulation thread and its frame pacer (mirrors the macOS
/// <c>EmulationLoop</c>).
///
/// <para>Emulation used to run inside <c>CompositionTarget.Rendering</c> on the
/// UI thread, so every UI hitch — a menu opening, a dialog, a slow present —
/// was also an emulation (and audio) hitch. It now runs on a dedicated thread
/// with its own wall-clock pacer; the UI thread only presents whatever frame
/// is finished (see <see cref="FramePublisher"/>).</para>
///
/// <para><b>Ownership contract.</b> The core stays confined to one thread at a
/// time: the <c>step</c> callback takes <see cref="EmulatorHost.SyncRoot"/>,
/// which every other host caller takes too, and re-checks
/// <see cref="ShouldRun"/> under it (see <see cref="Stop"/> for why).</para>
///
/// <para><b>Direction rule.</b> UI → emulation may block (taking the lock, or
/// <see cref="Stop"/> + join). Emulation → UI must always be asynchronous
/// (<c>DispatcherQueue.TryEnqueue</c>); a blocking wait in that direction
/// deadlocks.</para>
/// </summary>
internal sealed class EmulationLoop : IDisposable
{
    /// Runs one tick: a slice at x1, otherwise a batch of whole frames.
    private readonly Action<int> _step;

    private readonly object _lock = new();
    // Wakes the thread early from a pacing sleep or a park when the state changes.
    private readonly AutoResetEvent _wake = new(false);
    private readonly TimerWaitHandle _timer = new();

    private bool _running;
    private bool _visible = true;
    private bool _terminated;
    private int _framesPerStep = 1;
    private double _tickInterval = 1.0 / 60.0;
    // Set when the loop resumes, so the pacer does not try to make up for the
    // wall-clock time that passed while it was parked.
    private bool _pacingNeedsReset = true;
    private Thread? _thread;

    public EmulationLoop(Action<int> step) => _step = step;

    /// <summary>
    /// Whether a tick may run right now. Re-checked inside the host lock so
    /// that <see cref="Stop"/> can guarantee quiescence.
    /// </summary>
    public bool ShouldRun
    {
        get { lock (_lock) return _running && _visible && !_terminated; }
    }

    /// <summary>Machine frames per tick when not slicing (the emulation speed multiplier).</summary>
    public void SetFramesPerStep(int count)
    {
        lock (_lock) _framesPerStep = Math.Max(1, count);
        _wake.Set();
    }

    /// <summary>
    /// Wall-clock length of one tick. Fed from the machine's frame rate after
    /// every tick, so it follows the monitor type and whatever geometry the
    /// software has programmed into the CRTC.
    /// </summary>
    public void SetTickInterval(double seconds)
    {
        lock (_lock) _tickInterval = seconds;
    }

    /// <summary>
    /// Window visibility. Emulation parks while the window is minimized, which
    /// is what the UI-thread loop did as a side effect of Rendering stopping.
    /// </summary>
    public void SetVisible(bool visible)
    {
        lock (_lock)
        {
            if (_visible == visible) return;
            _visible = visible;
            _pacingNeedsReset = true;
        }
        _wake.Set();
    }

    /// <summary>Start (or resume) the loop, spawning the thread on first use.</summary>
    public void Start()
    {
        lock (_lock)
        {
            if (_terminated) return;
            _running = true;
            _pacingNeedsReset = true;
            if (_thread is null)
            {
                _thread = new Thread(Run)
                {
                    Name = "Bubilator88 emulation",
                    IsBackground = true,
                    Priority = ThreadPriority.AboveNormal,
                };
                _thread.Start();
            }
        }
        _wake.Set();
    }

    /// <summary>
    /// Park the loop and wait until no tick is in flight. The flag is cleared
    /// before <paramref name="join"/> (which takes the host lock) and the step
    /// re-checks <see cref="ShouldRun"/> under that lock; without the re-check
    /// a tick that had already decided to run could slip in behind the join
    /// and execute after this returned.
    /// </summary>
    public void Stop(Action? join = null)
    {
        lock (_lock) _running = false;
        _wake.Set();
        join?.Invoke();
    }

    /// <summary>
    /// Tear the thread down for good and wait for it to exit. Must happen
    /// before the host is disposed: a tick still inside the core would
    /// otherwise run on a destroyed context.
    /// </summary>
    public void Terminate()
    {
        Thread? thread;
        lock (_lock)
        {
            _running = false;
            _terminated = true;
            thread = _thread;
        }
        _wake.Set();
        thread?.Join();
    }

    public void Dispose()
    {
        Terminate();
        _wake.Dispose();
        _timer.Dispose();
    }

    private static double Now() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    private void Run()
    {
        double nextDue = Now();

        while (true)
        {
            bool parked;
            double interval;
            int batch;
            lock (_lock)
            {
                if (_terminated) return;
                parked = !(_running && _visible);
                if (!parked && _pacingNeedsReset)
                {
                    _pacingNeedsReset = false;
                    nextDue = Now();
                }
                interval = _tickInterval;
                batch = _framesPerStep;
            }

            if (parked)
            {
                _wake.WaitOne();
                continue;
            }

            double now = Now();
            if (now < nextDue)
            {
                // Sleep on a high-resolution timer: a plain timed wait is
                // rounded to the system tick (~15.6ms), far coarser than the
                // ~4.5ms x1 slice, which would bunch the slices back together.
                // The wake event cuts the sleep short on a state change.
                _timer.Wait(nextDue - now, _wake);
                continue;
            }

            // Catch-up safeguard: after a long stall (a disk swap, the machine
            // running slower than real time) do not replay the backlog — jump
            // the schedule forward instead.
            if (now - nextDue > 0.5)
                nextDue = now;

            _step(batch);
            lock (_lock) interval = _tickInterval;
            nextDue += interval;
        }
    }

    /// <summary>
    /// A waitable timer with sub-millisecond resolution
    /// (CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, Windows 10 1803+), falling back
    /// to a regular waitable timer where that flag is unsupported.
    /// </summary>
    private sealed class TimerWaitHandle : WaitHandle
    {
        private const uint CreateWaitableTimerHighResolution = 0x00000002;
        private const uint TimerAllAccess = 0x1F0003;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateWaitableTimerExW(IntPtr attributes, string? name, uint flags, uint access);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetWaitableTimer(SafeWaitHandle timer, ref long dueTime, int period,
                                                    IntPtr completion, IntPtr arg,
                                                    [MarshalAs(UnmanagedType.Bool)] bool resume);

        public TimerWaitHandle()
        {
            IntPtr h = CreateWaitableTimerExW(IntPtr.Zero, null, CreateWaitableTimerHighResolution, TimerAllAccess);
            if (h == IntPtr.Zero)
                h = CreateWaitableTimerExW(IntPtr.Zero, null, 0, TimerAllAccess);
            if (h == IntPtr.Zero)
                throw new InvalidOperationException($"CreateWaitableTimerExW failed ({Marshal.GetLastWin32Error()})");
            SafeWaitHandle = new SafeWaitHandle(h, ownsHandle: true);
        }

        /// Wait up to <paramref name="seconds"/>, or until <paramref name="wake"/> is signalled.
        public void Wait(double seconds, WaitHandle wake)
        {
            // Relative due time, in 100ns units (negative = relative).
            long due = -Math.Max(1L, (long)(seconds * 10_000_000.0));
            if (!SetWaitableTimer(SafeWaitHandle, ref due, 0, IntPtr.Zero, IntPtr.Zero, false))
            {
                Thread.Yield();
                return;
            }
            _pair ??= new[] { this, wake };
            WaitAny(_pair);
        }

        private WaitHandle[]? _pair;   // reused: this runs several hundred times a second
    }
}
