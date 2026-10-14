#!/usr/bin/env python3
"""Split a WAV of isolated hits, separated by silence, into one file per hit.

Made for cutting rhythm samples (2608_BD.WAV and so on) out of one recording.
A hit starts at the first frame whose peak over all channels exceeds the
threshold and ends once the level stays at or below it for 300 ms. Each file
keeps 2 ms before the hit and 20 ms after it, in the input format (16-bit PCM
only). For each file it prints the start, length, peak and a rough brightness
(zero-crossing rate of the first channel over the first 50 ms) to help tell
the drums apart.

Usage: split_wav_hits.py IN.wav OUTDIR PREFIX [THRESHOLD]
Writes OUTDIR/PREFIX_01.wav, PREFIX_02.wav, ... THRESHOLD defaults to 40.
"""
import array
import os
import sys
import wave

GAP = 0.3
PRE_ROLL = 0.002
POST_ROLL = 0.02


def find_hits(peak, threshold, gap):
    hits, i, n = [], 0, len(peak)
    while i < n:
        if peak[i] <= threshold:
            i += 1
            continue
        start = last = j = i
        while j < n and j - last < gap:
            if peak[j] > threshold:
                last = j
            j += 1
        hits.append((start, last + 1))
        i = j
    return hits


def main():
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    src, outdir, prefix = sys.argv[1:4]
    threshold = int(sys.argv[4]) if len(sys.argv) == 5 else 40

    with wave.open(src) as w:
        if w.getsampwidth() != 2:
            sys.exit("only 16-bit PCM is supported")
        n, rate, ch = w.getnframes(), w.getframerate(), w.getnchannels()
        samples = array.array("h", w.readframes(n))
    if sys.byteorder == "big":
        samples.byteswap()

    peak = [max(abs(samples[i * ch + c]) for c in range(ch)) for i in range(n)]
    pre, post = int(rate * PRE_ROLL), int(rate * POST_ROLL)
    os.makedirs(outdir, exist_ok=True)
    for k, (s, e) in enumerate(find_hits(peak, threshold, int(rate * GAP)), 1):
        s0, e0 = max(0, s - pre), min(n, e + post)
        out = samples[s0 * ch:e0 * ch]
        if sys.byteorder == "big":
            out.byteswap()
        path = os.path.join(outdir, f"{prefix}_{k:02d}.wav")
        with wave.open(path, "wb") as o:
            o.setnchannels(ch)
            o.setsampwidth(2)
            o.setframerate(rate)
            o.writeframes(out.tobytes())
        head = [samples[(s + t) * ch] for t in range(min(e - s, rate // 20))]
        crossings = sum(1 for x, y in zip(head, head[1:]) if (x < 0) != (y < 0))
        zcr = crossings / (len(head) / rate) / 2 if head else 0
        print(f"{os.path.basename(path)}  {s0 / rate:6.2f}s  {(e0 - s0) / rate:5.2f}s"
              f"  peak {max(peak[s:e])}  ~{zcr:.0f} Hz")


if __name__ == "__main__":
    main()
