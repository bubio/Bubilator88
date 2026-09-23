#!/usr/bin/env python3
"""Build an original, bootable PC-8801 mixed-raster detective scene disk."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
VRAMTEST = HERE.parent / "vramtest"
SOURCE_ART = HERE / "source-art.png"
ROOM_ART = HERE / "room-art.png"
DETECTIVE_ART = HERE / "detective-art.png"

# Four logical colors in each 25-line output band. The red GVRAM plane is
# reserved for the lower panel, so palette entries differing only in the red
# bit are paired. Reprogramming the analog palette between bands gives the
# upper image more colors across its 200 output lines without glyph ghosts.
# Components are 3-bit R, G, B values (512-color analog palette).
BAND_COLORS = [
    [(0, 0, 1), (0, 2, 4), (7, 3, 0), (7, 7, 7)],
    [(0, 0, 1), (0, 2, 5), (7, 3, 0), (7, 7, 7)],
    [(0, 0, 1), (1, 3, 5), (6, 2, 0), (7, 7, 6)],
    [(0, 0, 1), (0, 3, 5), (6, 3, 0), (7, 7, 7)],
    [(0, 0, 1), (0, 4, 5), (7, 4, 1), (7, 7, 7)],
    [(0, 0, 1), (1, 4, 4), (7, 4, 1), (7, 7, 6)],
    [(1, 0, 0), (2, 2, 3), (6, 3, 0), (7, 7, 7)],
    [(1, 0, 0), (3, 2, 2), (6, 3, 0), (7, 7, 7)],
]
ROOM_BAND_COLORS = [
    [(2, 1, 0), (7, 6, 3), (3, 5, 6), (7, 7, 7)],
    [(2, 1, 0), (7, 6, 4), (2, 5, 7), (7, 7, 7)],
    [(2, 1, 0), (7, 6, 4), (2, 5, 6), (7, 7, 7)],
    [(2, 1, 0), (7, 6, 3), (1, 5, 6), (7, 7, 7)],
    [(2, 1, 0), (7, 5, 2), (2, 4, 5), (7, 7, 7)],
    [(2, 1, 0), (7, 5, 2), (2, 4, 4), (7, 7, 7)],
    [(2, 1, 0), (6, 4, 1), (2, 3, 3), (7, 7, 7)],
    [(1, 0, 0), (6, 4, 1), (2, 3, 3), (7, 7, 7)],
]

sys.path.insert(0, str(VRAMTEST))
from build import d88_image  # noqa: E402


def top_picture(source_path, colors_by_band, crop_top):
    """Quantize each raster band to its four active analog colors."""
    source = Image.open(source_path).convert("RGB")
    height = round(source.width / 3.2)
    crop = source.crop((0, crop_top, source.width, crop_top + height))
    crop = crop.resize((640, 100), Image.Resampling.LANCZOS)
    pixels = bytearray(640 * 100)
    for band, colors in enumerate(colors_by_band):
        rgb = [tuple(round(component * 255 / 7) for component in color)
               for color in colors]
        first = band * 100 // len(colors_by_band)
        last = (band + 1) * 100 // len(colors_by_band)
        area = crop.crop((0, first, 640, last))
        source_bytes = area.tobytes()
        for offset in range(area.width * area.height):
            pixel = source_bytes[offset * 3:offset * 3 + 3]
            closest = min(range(4), key=lambda i: sum(
                (pixel[channel] - rgb[i][channel]) ** 2 for channel in range(3)))
            pixels[first * 640 + offset] = (0, 1, 4, 5)[closest]
    return Image.frombytes("P", (640, 100), bytes(pixels))


def palette_bytes(colors):
    """Eight analog entries paired to hide the shared red-plane content."""
    pairs = [colors[0], colors[1], colors[0], colors[1],
             colors[2], colors[3], colors[2], colors[3]]
    data = bytearray()
    for red, green, blue in pairs:
        data.extend(((red << 3) | blue, 0x40 | green))
    return data


def panel_base():
    """Monochrome frame and portrait; all characters come from Kanji ROM."""
    im = Image.new("1", (640, 200), 0)
    d = ImageDraw.Draw(im)
    d.rectangle((2, 2, 637, 197), outline=1, width=2)
    d.line((14, 35, 625, 35), fill=1, width=1)
    # Fine one-pixel portrait details are visible only in the 400-line band.
    d.rectangle((17, 46, 132, 151), outline=1, width=2)
    portrait = Image.open(DETECTIVE_ART).convert("L")
    portrait = portrait.crop((60, 100, 1085, 1125))
    portrait = portrait.resize((110, 102), Image.Resampling.LANCZOS)
    portrait = portrait.point(lambda value: 255 if value > 125 else 0, mode="1")
    im.paste(portrait, (20, 48))
    d.line((149, 135, 624, 135), fill=1)
    d.line((150, 168, 624, 168), fill=1)
    return im


def rom_address(char):
    encoded = char.encode("iso2022_jp")
    if not encoded.startswith(b"\x1b$B") or len(encoded) != 8:
        raise ValueError(f"Not a JIS X 0208 character: {char!r}")
    jis = (encoded[3] << 8) | encoded[4]
    if 0x2100 <= jis < 0x2800:
        return ((jis & 0x001F) << 4) | ((jis & 0x0060) << 7) | ((jis & 0x0700) << 1)
    if 0x3000 <= jis < 0x5000:
        return ((jis & 0x001F) << 4) | ((jis & 0x0060) << 9) | ((jis & 0x1F00) << 1)
    raise ValueError(f"Character is outside first-level Kanji ROM: {char!r}")


TEXT = {
    "PortTitle": ["雨の港・第七倉庫"],
    "PortChapter": ["第一章　消えた設計図"],
    "PortChoices": ["１　机を調べる　２　窓を見る　３　移動"],
    "RoomTitle": ["探偵事務所・資料室"],
    "RoomChapter": ["第二章　朝の手がかり"],
    "RoomChoices": ["１　机を調べる　２　窓を見る　３　港へ戻る"],
    "ResetLine": ["０　最初から"],
    "IntroLines": ["午前二時、雨の港に着いた。",
                   "倉庫の机には濡れた封筒。",
                   "設計図を盗んだ者の名が、ここに？"],
    "ClueLines": ["机の引き出しに、濡れた鍵が一本。",
                  "刻印は「七」。今夜の客が落としたのか。",
                  "窓辺にも、何か手がかりがありそうだ。"],
    "WindowLines": ["窓の外で、青い灯が二度またたく。",
                    "港の巡視艇だ。誰かを待っているらしい。",
                    "鍵の持ち主は、もう倉庫を出たのか？"],
    "RoomIntroLines": ["港を離れ、明るい資料室へ戻った。",
                       "机には古い航路図と、七番の鍵。",
                       "朝の光が、封筒の文字を照らす。"],
    "RoomClueLines": ["資料の間に、倉庫の見取り図があった。",
                      "印のある部屋は、昨夜は空だったはず。",
                      "誰が先に、ここへ入ったのだろう。"],
    "RoomWindowLines": ["窓辺に、一枚の写真が立ててある。",
                        "写っている船は、あの港の巡視艇だ。",
                        "船長の顔に見覚えがある。"],
}


def plane_bytes(im, bit):
    data = bytearray()
    for y in range(200):
        for x in range(0, 640, 8):
            byte = 0
            for dx in range(8):
                if y < im.height and (im.getpixel((x + dx, y)) & bit):
                    byte |= 0x80 >> dx
            data.append(byte)
    return bytes(data)


def compress(data):
    out = bytearray()
    i = 0
    while i < len(data):
        run = 1
        while i + run < len(data) and data[i + run] == data[i] and run < 127:
            run += 1
        if run >= 3:
            out.extend((0x80 | run, data[i]))
            i += run
            continue
        start = i
        i += run
        while i < len(data) and i - start < 127:
            run = 1
            while i + run < len(data) and data[i + run] == data[i] and run < 3:
                run += 1
            if run >= 3 or i + run - start > 127:
                break
            i += run
        out.append(i - start)
        out.extend(data[start:i])
    out.append(0)
    return out


def asset_source(assets):
    lines = []
    for prefix, bands in (("Palette", BAND_COLORS), ("RoomPalette", ROOM_BAND_COLORS)):
        for band, colors in enumerate(bands):
            data = palette_bytes(colors)
            lines.append(f"{prefix}{band}:")
            lines.append("\t\tdb\t\t" + ",".join(f"${x:02X}" for x in data))
        lines.append(f"{prefix}Table:")
        lines.append("\t\tdw\t\t" + ",".join(
            f"{prefix}{band}" for band in range(1, len(bands))))
    for name, data in assets:
        lines.append(f"{name}:")
        for i in range(0, len(data), 16):
            lines.append("\t\tdb\t\t" + ",".join(f"${x:02X}" for x in data[i:i + 16]))
    for name, messages in TEXT.items():
        lines.append(f"{name}:")
        for message in messages:
            addresses = [rom_address(char) for char in message]
            data = bytearray()
            for address in addresses:
                data.extend((address & 0xFF, address >> 8))
            data.extend((0xFF, 0xFF))
            for i in range(0, len(data), 16):
                lines.append("\t\tdb\t\t" + ",".join(f"${x:02X}" for x in data[i:i + 16]))
    (HERE / "build" / "assets.inc").write_text("\n".join(lines) + "\n")


def assemble(source, output, defines=()):
    asl_dir = os.environ.get("ASL_DIR")
    asl = str(Path(asl_dir) / "asl") if asl_dir else shutil.which("asl")
    p2bin = str(Path(asl_dir) / "p2bin") if asl_dir else shutil.which("p2bin")
    if not asl or not p2bin:
        raise SystemExit("asl/p2bin not found; put them on PATH or set ASL_DIR")
    env = dict(os.environ)
    if asl_dir:
        env.setdefault("AS_MSGPATH", asl_dir)
    obj = HERE / "build" / (source.stem + ".p")
    command = [asl, "-cpu", "z80undoc", "-q", "-o", str(obj),
               "-i", str(HERE / "build"), "-i", str(VRAMTEST / "src")]
    for definition in defines:
        command += ["-D", definition]
    subprocess.run(command + [str(source)], check=True, env=env)
    subprocess.run([p2bin, "-q", "-k", "-l", "0", "-r", "$-$",
                    str(obj), str(output)], check=True, env=env)
    return output.read_bytes()


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "rasterstory.d88"
    (HERE / "build").mkdir(exist_ok=True)
    port = top_picture(SOURCE_ART, BAND_COLORS, 120)
    room = top_picture(ROOM_ART, ROOM_BAND_COLORS, 80)
    assets = [("BlueData", compress(plane_bytes(port, 1))),
              ("GreenData", compress(plane_bytes(port, 4))),
              ("RoomBlueData", compress(plane_bytes(room, 1))),
              ("RoomGreenData", compress(plane_bytes(room, 4))),
              ("PanelBase", compress(plane_bytes(panel_base(), 1)))]
    asset_source(assets)
    program = assemble(HERE / "main.z80", HERE / "build" / "main.bin")
    sectors = (len(program) + 255) // 256
    if sectors > 120:
        raise SystemExit(f"Program is {len(program)} bytes; maximum is 30720")
    ipl = assemble(VRAMTEST / "src" / "ipl.z80", HERE / "build" / "ipl.bin",
                   [f"IMAGE_SECTORS={sectors}"])
    if len(ipl) > 256:
        raise SystemExit("IPL exceeds one sector")
    payload = {(0, 1): ipl}
    for index in range(sectors):
        linear = index + 1
        payload[(linear // 16, linear % 16 + 1)] = program[index * 256:(index + 1) * 256]
    out.write_bytes(d88_image("RASTER STORY", payload))
    print(f"{out}: {len(program)} program bytes, {sectors} sectors; "
          + ", ".join(f"{name}={len(data)}" for name, data in assets))


if __name__ == "__main__":
    main()
