#!/usr/bin/env python3
"""Extract one audio track of a CUE/BIN (or CUE/IMG) disc image to a WAV file.

Reads the raw 2352-byte sectors straight from the image, from the track's
INDEX 01 to the next track's INDEX 01 (or the end of the file), as 44.1kHz
16-bit stereo. Only single-FILE BINARY sheets are supported.

Usage: cd_track_to_wav.py DISC.cue TRACK OUT.wav
"""
import os
import re
import sys
import wave

SECTOR = 2352


def frames(msf):
    m, s, f = (int(x) for x in msf.split(":"))
    return (m * 60 + s) * 75 + f


def parse_cue(path):
    files, tracks, current = [], [], None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            words = line.strip().split()
            if not words:
                continue
            key = words[0].upper()
            if key == "FILE":
                files.append(re.search(r'"([^"]+)"', line).group(1) if '"' in line else words[1])
            elif key == "TRACK":
                current = {"number": int(words[1]), "type": words[2].upper()}
                tracks.append(current)
            elif key == "INDEX" and current is not None and int(words[1]) == 1:
                current["start"] = frames(words[2])
    if len(files) != 1:
        sys.exit("only single-FILE cue sheets are supported")
    return os.path.join(os.path.dirname(path), files[0]), tracks


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    cue, number, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    image, tracks = parse_cue(cue)
    index = next((i for i, t in enumerate(tracks) if t["number"] == number), None)
    if index is None:
        sys.exit(f"no track {number}")
    track = tracks[index]
    if track["type"] != "AUDIO":
        sys.exit(f"track {number} is {track['type']}, not AUDIO")
    end = (tracks[index + 1]["start"] if index + 1 < len(tracks)
           else os.path.getsize(image) // SECTOR)
    with open(image, "rb") as fh:
        fh.seek(track["start"] * SECTOR)
        data = fh.read((end - track["start"]) * SECTOR)
    with wave.open(out, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(44100)
        w.writeframes(data)
    print(f"track {number}: LBA {track['start']}-{end - 1}, "
          f"{(end - track['start']) / 75:.2f}s -> {out}")


if __name__ == "__main__":
    main()
