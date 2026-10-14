#!/usr/bin/env python3
"""Shape recorded drum hits after a reference set of YM2608 rhythm samples.

For each of BD SD TOP HH TOM RIM, reads SRCDIR/PREFIX_<NAME>.wav and the
reference REFDIR/2608_<NAME>.WAV, and writes OUTDIR/2608_<NAME>.WAV that
follows the reference in:

- format: mono 16-bit at the reference's rate (stereo is averaged, then
  resampled with afconvert, so this runs on macOS only);
- attack position: the hit starts (first sample above 5% of the peak) as many
  milliseconds into the file as it does in the reference;
- tone: a linear-phase EQ moves the energy of each octave band towards the
  reference's, by at most 18 dB either way;
- length and decay: after the peak, a gain that only ever attenuates bends
  the 5 ms peak envelope onto the reference's, and the file ends where the
  reference does, with a 2 ms fade;
- loudness: the A-weighted energy of the first 30 ms after the attack matches
  the reference's, unless that would push the peak past full scale.

The reference files are only measured, never copied into the output.

Usage: match_rhythm_samples.py SRCDIR PREFIX REFDIR OUTDIR
"""
import array
import cmath
import math
import os
import subprocess
import sys
import tempfile
import wave

NAMES = ["BD", "SD", "TOP", "HH", "TOM", "RIM"]
ONSET = 0.05
BLOCK_MS = 5
FLOOR = 10 ** (-80 / 20)
FADE_MS = 2
HEAD_MS = 30
EQ_LIMIT_DB = 18
EQ_HALF_TAPS = 511
BAND_CENTERS = [31.25 * 2 ** k for k in range(10)]  # 31 Hz to 16 kHz


def read(path):
    with wave.open(path) as w:
        if w.getsampwidth() != 2:
            sys.exit(f"{path}: only 16-bit PCM is supported")
        n, rate, ch = w.getnframes(), w.getframerate(), w.getnchannels()
        a = array.array("h", w.readframes(n))
    if sys.byteorder == "big":
        a.byteswap()
    return [sum(a[i * ch:i * ch + ch]) / ch for i in range(n)], rate


def write(path, x, rate):
    a = array.array("h", (max(-32768, min(32767, round(v))) for v in x))
    if sys.byteorder == "big":
        a.byteswap()
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(a.tobytes())


def resample(x, rate, target):
    if rate == target:
        return x
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "in.wav"), os.path.join(tmp, "out.wav")
        write(src, x, rate)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{target}",
                        "-r", "127", src, dst], check=True)
        return read(dst)[0]


def fft(values, inverse=False):
    """Iterative radix-2 FFT; the length must be a power of two."""
    a = [complex(v) for v in values]
    n = len(a)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j |= bit
        if i < j:
            a[i], a[j] = a[j], a[i]
    sign = 1 if inverse else -1
    size = 2
    while size <= n:
        step = cmath.exp(sign * 2j * math.pi / size)
        half = size // 2
        for start in range(0, n, size):
            w = 1
            for k in range(start, start + half):
                t = a[k + half] * w
                a[k + half] = a[k] - t
                a[k] += t
                w *= step
        size *= 2
    if inverse:
        a = [v / n for v in a]
    return a


def pow2(n):
    return 1 << max(0, n - 1).bit_length()


def onset(x):
    peak = max(abs(v) for v in x)
    return next(i for i, v in enumerate(x) if abs(v) > peak * ONSET)


def band_energy(x, rate):
    """Energy in each octave band of BAND_CENTERS."""
    n = pow2(len(x))
    spectrum = fft(x + [0] * (n - len(x)))
    energy = [0.0] * len(BAND_CENTERS)
    for k in range(1, n // 2):
        f = k * rate / n
        for b, c in enumerate(BAND_CENTERS):
            if c / math.sqrt(2) <= f < c * math.sqrt(2):
                energy[b] += abs(spectrum[k]) ** 2
    return energy


def equalize(x, ref, rate):
    """Filter x so that its octave bands lean towards ref's."""
    have, want = band_energy(x, rate), band_energy(ref, rate)
    total_have, total_want = sum(have), sum(want)
    gains = []
    for h, w in zip(have, want):
        db = 10 * math.log10((max(w, 1e-12) / total_want) / (max(h, 1e-12) / total_have))
        gains.append(max(-EQ_LIMIT_DB, min(EQ_LIMIT_DB, db)))

    # Frequency response interpolated in log frequency between band centres,
    # turned into a symmetric FIR and windowed.
    grid = 4096
    response = []
    for k in range(grid):
        f = min(k, grid - k) * rate / grid
        octave = math.log2(max(f, 1) / BAND_CENTERS[0])
        b = max(0, min(len(gains) - 1, math.floor(octave)))
        b1 = min(len(gains) - 1, b + 1)
        t = max(0.0, min(1.0, octave - b))
        response.append(10 ** ((gains[b] * (1 - t) + gains[b1] * t) / 20))
    impulse = [v.real for v in fft(response, inverse=True)]
    m = EQ_HALF_TAPS
    taps = [impulse[i % grid] * (0.5 + 0.5 * math.cos(math.pi * i / (m + 1)))
            for i in range(-m, m + 1)]

    n = pow2(len(x) + len(taps))
    y = fft(x + [0] * (n - len(x)))
    h = fft(taps + [0] * (n - len(taps)))
    out = fft([a * b for a, b in zip(y, h)], inverse=True)
    return [v.real for v in out[m:m + len(x)]], gains


def envelope(x, block):
    """Peak of each block, relative to the whole signal's peak."""
    peak = max(abs(v) for v in x)
    return [max(abs(v) for v in x[i:i + block]) / peak for i in range(0, len(x), block)]


def follow_decay(x, ref, rate):
    block = rate * BLOCK_MS // 1000
    have, want = envelope(x, block), envelope(ref, block)
    peak_block = max(range(len(have)), key=lambda k: have[k])

    gain = []
    for k in range(len(want)):
        if k <= peak_block or k >= len(have):
            gain.append(1.0)
        else:
            gain.append(min(1.0, max(want[k], FLOOR) / max(have[k], FLOOR)))
    # A median of three, then never rising again, so that a bump in the
    # recording does not make the gain pump.
    smooth = []
    for k in range(len(gain)):
        window = sorted(gain[max(0, k - 1):k + 2])
        smooth.append(window[len(window) // 2])
    for k in range(peak_block + 1, len(smooth)):
        smooth[k] = min(smooth[k], smooth[k - 1])

    out = []
    for i in range(min(len(x), len(ref))):
        pos = i / block - 0.5
        k = max(0, min(len(smooth) - 1, math.floor(pos)))
        k1 = min(len(smooth) - 1, k + 1)
        t = min(1.0, max(0.0, pos - k))
        out.append(x[i] * (smooth[k] * (1 - t) + smooth[k1] * t))
    fade = min(len(out), rate * FADE_MS // 1000)
    for j in range(fade):
        out[len(out) - fade + j] *= 0.5 + 0.5 * math.cos(math.pi * (j + 1) / fade)
    return out


def a_weight(f):
    def ra(f):
        f2 = f * f
        return (12194 ** 2 * f2 * f2 / ((f2 + 20.6 ** 2) * (f2 + 12194 ** 2)
                * math.sqrt((f2 + 107.7 ** 2) * (f2 + 737.9 ** 2))))
    return ra(f) / ra(1000)


def loudness(x, rate):
    """A-weighted RMS of the first HEAD_MS after the attack."""
    start = onset(x)
    head = x[start:start + rate * HEAD_MS // 1000]
    n = pow2(len(head))
    spectrum = fft(head + [0] * (n - len(head)))
    energy = sum(abs(spectrum[k]) ** 2 * a_weight(k * rate / n) ** 2 for k in range(1, n // 2))
    return math.sqrt(2 * energy / n / len(head))


def shape(x, ref, rate):
    # Equalize with room on both sides, then place the attack, so that the
    # filter's ringing does not move it.
    x = [0.0] * EQ_HALF_TAPS + x
    x = x[onset(x) - EQ_HALF_TAPS:][:len(ref) + 2 * EQ_HALF_TAPS]
    x, gains = equalize(x, ref, rate)
    x = x[max(0, onset(x) - onset(ref)):]
    out = follow_decay(x, ref, rate)
    scale = min(loudness(ref, rate) / loudness(out, rate),
                32767 / max(abs(v) for v in out))
    return [v * scale for v in out], gains


def describe(x, rate):
    peak = max(abs(v) for v in x)
    return (f"{len(x) / rate * 1000:5.0f} ms  onset {onset(x) / rate * 1000:4.1f} ms"
            f"  peak {20 * math.log10(peak / 32768):5.1f} dBFS"
            f"  loudness {20 * math.log10(loudness(x, rate) / 32768):5.1f} dBFS(A)")


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    srcdir, prefix, refdir, outdir = sys.argv[1:]
    os.makedirs(outdir, exist_ok=True)
    for name in NAMES:
        ref, rate = read(os.path.join(refdir, f"2608_{name}.WAV"))
        x, src_rate = read(os.path.join(srcdir, f"{prefix}_{name}.wav"))
        out, gains = shape(resample(x, src_rate, rate), ref, rate)
        write(os.path.join(outdir, f"2608_{name}.WAV"), out, rate)
        print(f"{name:3s} ref {describe(ref, rate)}")
        print(f"    out {describe(out, rate)}")
        print("    EQ  " + " ".join(f"{g:+.0f}" for g in gains) + " dB (31 Hz .. 16 kHz)")


if __name__ == "__main__":
    main()
