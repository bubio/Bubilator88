#!/usr/bin/env python3
"""Build the substitute kanji ROMs (KANJI1.ROM / KANJI2.ROM) from Shinonome.

The app loads these when the user has no kanji ROM of their own. The glyphs
come from the Shinonome bitmap fonts, which are in the public domain; only the
layout follows the real ROMs:

  * One ROM address holds two bytes: the left 8 dots (even byte, ports
    0xE9/0xED) and the right 8 dots (odd byte, ports 0xE8/0xEC). A full-width
    glyph is 16 addresses, one per row.
  * KANJI1 0x0000-0x0FFF: half-width 8x16 glyphs, 16 bytes per code, one byte
    per row.
  * Half-width codes 0x80-0x9F and 0xE0-0xFF hold hiragana, in the order of
    the katakana 0x20 away. Shinonome has no half-width hiragana, so these
    are its full-width ones squeezed to half the width.
  * KANJI1 0x1000-0x17FF holds an 8x8 font in the FONT.ROM layout. It is
    copied from the core's built-in font (QUASI88's `built_in_font_ANK`),
    read through `b88_glyph` in the core's C ABI library.
  * Full-width glyphs sit at the word address computed by `jis_to_address`.
  * Unassigned slots hold a filler pattern on the real ROMs; here they are 0.

The core library is built with
  swift build --package-path ../Bubilator88Core --product Bubilator88C

Usage:
  scripts/make_substitute_kanji_rom.py                 # write Shared/SubstituteKanji/
  scripts/make_substitute_kanji_rom.py --compare K1 K2 # check slot coverage
  scripts/make_substitute_kanji_rom.py --compare K1 K2 --show 3021 3033

`--compare` reads real ROMs only to report where they and the substitute
disagree; nothing from them is written out.
"""

import argparse
import ctypes
import hashlib
import os
import sys
import tarfile
import tempfile
import unicodedata
import urllib.request
from pathlib import Path

FONT_URL = "http://openlab.ring.gr.jp/efont/dist/shinonome/shinonome-0.9.11p1.tar.bz2"
FONT_SHA256 = "95663c95c92ba5765f63ccbdf033eb93b707be01812a989c548db943479c838f"
FONT_ROOT = "shinonome-0.9.11"
FULL_WIDTH_BDF = "bdf/shnmk16.bdf"
HALF_WIDTH_BDF = "bdf/shnm8x16r.bdf"

ROM_SIZE = 0x20000
OUT_DIR = Path(__file__).resolve().parent.parent / "Shared" / "SubstituteKanji"
CORE_DIR = Path(os.environ.get("BUBILATOR88_CORE_DIR",
                               Path(__file__).resolve().parent.parent.parent / "Bubilator88Core"))
CORE_LIB = CORE_DIR / ".build" / "debug" / "libBubilator88C.dylib"
FONT_8X8_OFFSET = 0x1000


def jis_to_address(code):
  """The ROM (1 or 2) and word address of a JIS X 0208 code, or None.

  The bit layout is the one QUASI88's menu uses to draw from the kanji ROM,
  checked against real KANJI1/KANJI2 dumps.
  """
  row, col = code >> 8, code & 0xFF
  if not (0x21 <= col <= 0x7E):
    return None
  if 0x21 <= row <= 0x2F:
    # Non-kanji. Row 0x28 lands on the slots of row 0x20, which has no glyphs.
    return 1, ((code & 0x0060) << 7) | ((code & 0x0700) << 1) | ((code & 0x001F) << 4)
  if 0x30 <= row <= 0x4F:
    return 1, ((code & 0x0060) << 9) | ((code & 0x1F00) << 1) | ((code & 0x001F) << 4)
  if 0x50 <= row <= 0x6F:
    return 2, (((code & 0x0060) << 9) | ((code & 0x0F00) << 1) | ((code & 0x001F) << 4)
               | (code & 0x2000))
  if 0x70 <= row <= 0x77:
    return 2, ((code & 0x0060) << 7) | ((code & 0x0700) << 1) | ((code & 0x001F) << 4)
  return None


def parse_bdf(path):
  """Map each encoding to its glyph rows, as cell-wide integers, MSB left."""
  lines = path.read_text(encoding="latin-1").splitlines()
  cell_w = cell_h = cell_x = cell_y = 0
  glyphs = {}
  i = 0
  while i < len(lines):
    fields = lines[i].split()
    if not fields:
      i += 1
      continue
    if fields[0] == "FONTBOUNDINGBOX":
      cell_w, cell_h, cell_x, cell_y = map(int, fields[1:5])
    elif fields[0] == "STARTCHAR":
      encoding = None
      bbx = None
      i += 1
      while not lines[i].startswith("BITMAP"):
        f = lines[i].split()
        if f[0] == "ENCODING":
          encoding = int(f[1])
        elif f[0] == "BBX":
          bbx = list(map(int, f[1:5]))
        i += 1
      w, h, x, y = bbx
      bits = [int(lines[i + 1 + r], 16) for r in range(h)]
      i += h + 1
      stored = (w + 7) // 8 * 8
      top = (cell_h + cell_y) - (h + y)
      left = x - cell_x
      rows = [0] * cell_h
      for r, value in enumerate(bits):
        if 0 <= top + r < cell_h:
          rows[top + r] = (value >> (stored - w)) << (cell_w - w - left)
      if encoding is not None and encoding >= 0:
        glyphs[encoding] = rows
    i += 1
  return glyphs


def fetch_font_dir(work):
  """Download and unpack Shinonome into `work`, checking its digest."""
  archive = work / "shinonome.tar.bz2"
  with urllib.request.urlopen(FONT_URL) as response:
    archive.write_bytes(response.read())
  digest = hashlib.sha256(archive.read_bytes()).hexdigest()
  if digest != FONT_SHA256:
    sys.exit(f"unexpected SHA-256 for {FONT_URL}: {digest}")
  unpacked = work / "unpacked"
  with tarfile.open(archive) as tar:
    tar.extractall(unpacked, filter="data")
  return unpacked / FONT_ROOT


def builtin_font(lib_path):
  """The core's built-in 8x8 font, 8 bytes per code for all 256 codes."""
  if not lib_path.exists():
    sys.exit(f"{lib_path} is missing; build it with\n"
             f"  swift build --package-path {CORE_DIR} --product Bubilator88C")
  lib = ctypes.CDLL(str(lib_path))
  lib.b88_create.restype = ctypes.c_void_p
  lib.b88_destroy.argtypes = [ctypes.c_void_p]
  lib.b88_glyph.argtypes = [ctypes.c_void_p, ctypes.c_int32,
                            ctypes.POINTER(ctypes.c_uint8), ctypes.c_int32]
  lib.b88_glyph.restype = ctypes.c_int32
  handle = lib.b88_create()
  font = bytearray()
  for code in range(256):
    cell = (ctypes.c_uint8 * 8)()
    if lib.b88_glyph(handle, code, cell, 8) != 8:
      sys.exit(f"b88_glyph returned no glyph for {code:02X}")
    font += bytes(cell)
  lib.b88_destroy(handle)
  return font


def half_width_hiragana(half, full):
  """Glyphs for half-width codes 0x80-0x9F and 0xE0-0xFF.

  Each holds the hiragana for the katakana 0x20 away (0x9C し for 0xBC シ,
  0xE0 た for 0xC0 タ). Codes whose katakana has no hiragana, such as
  punctuation, the long vowel mark and the voicing marks, repeat the
  half-width katakana glyph, as on the real ROM.
  """
  glyphs = {}
  for kana in range(0xA1, 0xE0):
    code = kana - 0x20 if kana < 0xC0 else kana + 0x20
    char = unicodedata.normalize("NFKC", bytes([kana]).decode("shift_jis"))
    if not "\u30A1" <= char <= "\u30F3":
      glyphs[code] = half[kana]
      continue
    euc = chr(ord(char) - 0x60).encode("euc-jp")
    rows = full[((euc[0] << 8) | euc[1]) & 0x7F7F]
    # Each pair of dots becomes one, lit when either was.
    glyphs[code] = [sum(1 << (7 - i) for i in range(8) if (row >> (14 - i * 2)) & 3)
                    for row in rows]
  return glyphs


def build(font_dir, lib_path):
  """Return (KANJI1, KANJI2) as bytearrays."""
  roms = {1: bytearray(ROM_SIZE), 2: bytearray(ROM_SIZE)}
  used = set()
  half = parse_bdf(font_dir / HALF_WIDTH_BDF)
  full = parse_bdf(font_dir / FULL_WIDTH_BDF)

  half_width = {code: rows for code, rows in half.items()
                if 0x21 <= code <= 0x7E or 0xA1 <= code <= 0xDF}
  half_width.update(half_width_hiragana(half, full))
  for code, rows in half_width.items():
    roms[1][code * 16:code * 16 + 16] = bytes(rows)

  font = builtin_font(lib_path)
  roms[1][FONT_8X8_OFFSET:FONT_8X8_OFFSET + len(font)] = font

  for code, rows in full.items():
    target = jis_to_address(code)
    if target is None:
      sys.exit(f"JIS {code:04X} has no place in the kanji ROM")
    if target in used:
      sys.exit(f"JIS {code:04X} collides with another glyph")
    used.add(target)
    rom, address = target
    offset = address * 2
    for r, value in enumerate(rows):
      roms[rom][offset + r * 2] = value >> 8
      roms[rom][offset + r * 2 + 1] = value & 0xFF
  return roms[1], roms[2]


def slot_bytes(rom, address):
  return rom[address * 2:address * 2 + 32]


def is_filler(cell):
  """The real ROMs fill unassigned slots with one row repeated."""
  rows = [cell[i:i + 2] for i in range(0, 32, 2)]
  return any(cell) and all(row == rows[0] for row in rows)


def compare(generated, real_paths):
  """Report slots one ROM fills and the other leaves empty."""
  real = [Path(p).read_bytes() for p in real_paths]
  for index in (0, 1):
    name = f"KANJI{index + 1}"
    gen, ref = generated[index], real[index]
    only_real, only_gen, both = [], [], 0
    first = 0x2000 if index == 0 else 0
    for slot in range(first // 32, ROM_SIZE // 32):
      g = gen[slot * 32:slot * 32 + 32]
      r = ref[slot * 32:slot * 32 + 32]
      real_has = any(r) and not is_filler(r)
      if any(g) and real_has:
        both += 1
      elif real_has:
        only_real.append(slot * 16)
      elif any(g):
        only_gen.append(slot * 16)
    print(f"{name}: both {both}, real only {len(only_real)}, substitute only {len(only_gen)}")
    for label, addresses in (("real only", only_real), ("substitute only", only_gen)):
      if addresses:
        codes = [address_to_jis(index + 1, a) for a in addresses]
        print(f"  {label}: " + " ".join(f"{c:04X}" if c else f"@{a:04X}"
                                         for c, a in zip(codes, addresses)))
  # Half-width area of KANJI1.
  gen, ref = generated[0], real[0]
  differ = [c for c in range(256) if any(gen[c * 16:c * 16 + 16]) != any(ref[c * 16:c * 16 + 16])]
  print("half-width codes filled on one side only: " + " ".join(f"{c:02X}" for c in differ))
  base = FONT_8X8_OFFSET
  differ = [c for c in range(256) if gen[base + c * 8:base + c * 8 + 8] != ref[base + c * 8:base + c * 8 + 8]]
  print("8x8 codes that differ: " + " ".join(f"{c:02X}" for c in differ))


def address_to_jis(rom, address):
  for row in range(0x21, 0x78):
    for col in range(0x21, 0x7F):
      if jis_to_address((row << 8) | col) == (rom, address):
        return (row << 8) | col
  return None


def show(generated, real_paths, codes):
  """Print each code's glyph from the real ROM and the substitute side by side."""
  real = [Path(p).read_bytes() for p in real_paths] if real_paths else []
  for code in codes:
    target = jis_to_address(code)
    if target is None:
      print(f"{code:04X}: not a kanji ROM code")
      continue
    rom, address = target
    sources = [real[rom - 1]] if real else []
    sources.append(generated[rom - 1])
    print(f"{code:04X} (KANJI{rom} @{address:04X})")
    for r in range(16):
      line = []
      for source in sources:
        cell = slot_bytes(source, address)
        value = (cell[r * 2] << 8) | cell[r * 2 + 1]
        line.append(format(value, "016b").replace("0", ".").replace("1", "#"))
      print("  " + "   ".join(line))


def main():
  parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
  parser.add_argument("--font-dir", type=Path, help="an unpacked Shinonome tree (skips the download)")
  parser.add_argument("--out-dir", type=Path, default=OUT_DIR)
  parser.add_argument("--core-lib", type=Path, default=CORE_LIB,
                      help="the core's C ABI library, for the built-in 8x8 font")
  parser.add_argument("--compare", nargs=2, metavar=("KANJI1", "KANJI2"),
                      help="real ROMs to check slot coverage against; nothing is written")
  parser.add_argument("--show", nargs="+", metavar="JIS", help="JIS codes (hex) to print")
  args = parser.parse_args()

  with tempfile.TemporaryDirectory() as work:
    font_dir = args.font_dir or fetch_font_dir(Path(work))
    generated = build(font_dir, args.core_lib)
    if args.compare or args.show:
      if args.compare:
        compare(generated, args.compare)
      if args.show:
        show(generated, args.compare, [int(c, 16) for c in args.show])
      return
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for index, data in enumerate(generated):
      (args.out_dir / f"SubstituteKANJI{index + 1}.ROM").write_bytes(data)
    license_text = (font_dir / "LICENSE").read_bytes().decode("euc-jp")
    (args.out_dir / "Shinonome-LICENSE.txt").write_text(license_text, encoding="utf-8")
    print(f"wrote {args.out_dir}")


if __name__ == "__main__":
  main()
