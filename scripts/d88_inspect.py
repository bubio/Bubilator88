#!/usr/bin/env python3
"""Inspect a D88 disk image: header, track table and per-track sector layout.

Usage: d88_inspect.py <image.d88> [--sectors] [--dump C:H:R]

Prints anything that breaks the format (track offsets out of range, sector
counts that disagree, data sizes that do not match N, odd status codes) so a
broken image can be told apart from an emulator bug.
"""
import struct
import sys

MEDIA = {0x00: "2D", 0x10: "2DD", 0x20: "2HD", 0x30: "1D", 0x40: "1DD"}


def parse(path):
  data = open(path, "rb").read()
  name = data[0:17].split(b"\0")[0]
  wp, media = data[0x1A], data[0x1B]
  size = struct.unpack_from("<I", data, 0x1C)[0]
  offsets = list(struct.unpack_from("<164I", data, 0x20))
  # The table may be shorter than 164 entries: the first track's offset marks
  # where the table ends.
  first = min((o for o in offsets if o), default=0x2B0)
  count = (first - 0x20) // 4 if first >= 0x20 else 164
  offsets = offsets[:min(count, 164)]
  return data, name, wp, media, size, offsets


def sectors_of(data, off, problems, track):
  out = []
  pos = off
  expected = None
  while True:
    if pos + 16 > len(data):
      problems.append(f"track {track}: sector header past end of file at 0x{pos:X}")
      break
    c, h, r, n, nsec, dens, dele, stat = struct.unpack_from("<4BHBBB", data, pos)
    dsize = struct.unpack_from("<H", data, pos + 14)[0]
    if expected is None:
      expected = nsec
    elif nsec != expected:
      problems.append(f"track {track}: sector count field {nsec} != {expected} (R={r})")
    if n <= 7 and dsize != (128 << n) and stat == 0:
      problems.append(f"track {track}: C{c} H{h} R{r} N{n} data size {dsize} != {128 << n}")
    out.append(dict(c=c, h=h, r=r, n=n, nsec=nsec, dens=dens, dele=dele, stat=stat,
                    size=dsize, pos=pos))
    pos += 16 + dsize
    if len(out) >= expected or expected == 0:
      break
  return out, pos


def main():
  args = sys.argv[1:]
  if not args:
    print(__doc__)
    sys.exit(1)
  path = args[0]
  show = "--sectors" in args
  dump = None
  if "--dump" in args:
    dump = tuple(int(x, 0) for x in args[args.index("--dump") + 1].split(":"))
  data, name, wp, media, size, offsets = parse(path)
  problems = []
  print(f"file      : {path}")
  print(f"name      : {name!r}")
  print(f"protect   : 0x{wp:02X}   media: 0x{media:02X} ({MEDIA.get(media, '?')})")
  print(f"disk size : {size} (file {len(data)})")
  if size != len(data):
    problems.append(f"header disk size {size} != file size {len(data)}")
  used = [(i, o) for i, o in enumerate(offsets) if o]
  print(f"tracks    : {len(used)} with data, table of {len(offsets)}")
  ends = []
  for i, off in used:
    if off >= len(data):
      problems.append(f"track {i}: offset 0x{off:X} past end of file")
      continue
    secs, end = sectors_of(data, off, problems, i)
    ends.append((off, end, i))
    if not secs:
      continue
    s0 = secs[0]
    rs = [s["r"] for s in secs]
    cyl, head = i // 2, i % 2
    odd = [s for s in secs if s["c"] != cyl or s["h"] != head]
    stats = sorted({s["stat"] for s in secs})
    dens = "FM" if s0["dens"] == 0x40 else "MFM"
    line = (f"  T{i:3d} @0x{off:06X} {len(secs):2d} sec {dens} N={sorted({s['n'] for s in secs})} "
            f"R={min(rs)}..{max(rs)}")
    if odd:
      line += f" CH={sorted({(s['c'], s['h']) for s in odd})}"
    if stats != [0]:
      line += f" status={[hex(x) for x in stats]}"
    if any(s["dele"] for s in secs):
      line += " deleted"
    if len(set(rs)) != len(rs):
      line += " dupR"
    if show or odd or stats != [0]:
      print(line)
      if show:
        for s in secs:
          print(f"      C{s['c']:02X} H{s['h']:02X} R{s['r']:02X} N{s['n']} size={s['size']} "
                f"dens=0x{s['dens']:02X} del=0x{s['dele']:02X} st=0x{s['stat']:02X}")
    if dump and dump[0] == cyl and dump[1] == head:
      for s in secs:
        if s["r"] == dump[2]:
          body = data[s["pos"] + 16:s["pos"] + 16 + s["size"]]
          for k in range(0, len(body), 16):
            chunk = body[k:k + 16]
            asc = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
            print(f"      {k:04X}: {chunk.hex(' ')}  {asc}")
  ends.sort()
  for (o1, e1, t1), (o2, _, t2) in zip(ends, ends[1:]):
    if e1 > o2:
      problems.append(f"track {t1} runs into track {t2} (ends 0x{e1:X}, next 0x{o2:X})")
  if ends and ends[-1][1] != len(data):
    problems.append(f"last track ends at 0x{ends[-1][1]:X}, file is 0x{len(data):X}")
  print("problems  :" + (" none" if not problems else ""))
  for p in problems:
    print("  - " + p)


if __name__ == "__main__":
  main()
