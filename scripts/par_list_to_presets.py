#!/usr/bin/env python3
"""Convert KAJA's "PC88-PAR改造部屋" code list into the app's cheat presets.

Usage:
    scripts/par_list_to_presets.py <list.pdf | list.txt> [output.json]

The input is the Wayback Machine page (web.archive.org/web/20010421074614/
http://www5.airnet.ne.jp/kajapon/pc88par.html) printed to PDF, or the text
already extracted from it. That text is kept in the private dev-docs as
docs/develop/PAR/KAJA_PC88PAR.txt and regenerates the shipped JSON byte for
byte. A PDF is read through PDFKit with `swift`, so that path runs on macOS
only. The output defaults to
Bubilator88/Resources/CheatPresets.json.

The page is a run of game titles, each followed by `- heading -` lines and the
codes under them, with prose notes in between. Titles cannot be told from
notes by shape alone, so they are listed in TITLES below; a new revision of
the list needs that updated. Notes become `;` comments: those about the whole
game at the top of the file, where the app shows them under the game's name,
and those about one group under its `#` line, where `PATFile.parse` makes
them the group's notes (see parse_groups). The source is credited on the last
line. A code line giving
alternative addresses for different releases (`D0004F48 3195 | D0002808
C195`) becomes one group per release, named by VARIANTS or numbered.
"""

import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

SOURCE = "KAJA「PC88-PAR改造部屋」(2001)"

TITLES = [
    "天地を喰らう", "女神転生", "メルヘンヴェール", "ヴァリス", "ヴァリス２", "ヴェイグス",
    "XZR", "XZR2", "STAR SYMPHONY", "VALNA", "DINOSAUR", "死霊戦線", "死霊戦線２", "ARGO",
    "MID GARTS", "PHYCHIC WAR", "WORLD GOLF 2", "WORLD GOLF 3", "ARCUS", "ARCUS 2",
    "抜忍伝説", "ADVANCED FANTASIAN", "ナイルの涙", "英雄ヤマトタケル", "GANDHARA",
    "DRAGON KNIGHT", "DRAGON KNIGHT 2", "SILVER GHOST", "RUNE WORTH", "ZAVAS",
    "EMERALD DRAGON", "WOODY POCO", "TIR-NA-NOG", "WIBARM", "THE SCREAMER", "MAKAKARA",
    "CHAOS ANGELS", "KING BREEDER", "JOTUNN", "ゼリアード", "夢幻の心臓", "夢幻の心臓２",
    "夢幻の心臓３", "CRIMSON", "CRIMSON 2", "CRIMSON 3", "MILLION CHECKER", "SILPHEED",
    "ぎゅわんぶらぁ自己中心派", "PIAS", "FINAL CRISIS", "スペースハリアー", "ドラゴンスレイヤー",
    "ドラゴンスレイヤー 英雄伝説", "ドラゴンスレイヤー 英雄伝説２", "ファンタジアン",
    "ＨＹＤＬＩＤＥ", "ＨＹＤＬＩＤＥ ２", "ＨＹＤＬＩＤＥ ３", "ＴＨＥ ＳＣＨＥＭＥ",
    "ＳＯＲＣＥＲＩＡＮ", "Ｘａｋ", "Ｘａｋ２", "Ｘａｋ ガゼルの塔", "ＸＡＮＡＤＵ",
    "ＸＡＮＡＤＵ シナリオ２", "Ｙｓ", "Ｙｓ２", "Ｙｓ３",
]

# Names for the releases of a game whose codes give alternatives, left to right.
VARIANTS = {
    "ドラゴンスレイヤー": ["Falcom版", "ログイン版"],
}

# Games whose headings have no codes of their own because the list says
# "same as" another game: those headings take the other game's codes.
SAME_AS = {
    "ＸＡＮＡＤＵ シナリオ２": "ＸＡＮＡＤＵ",
}

END = "[戻る]"
PAGE_FURNITURE = re.compile(
    r"^(=== page|PC88-PAR改造部屋$|\d{4}/\d\d/\d\d \d\d:\d\d$|https://web\.archive|"
    r"The Wayback Machine|\d+ / \d+ページ$)")
CODE = re.compile(r"^[0-9A-F]{8}( [0-9A-F]{4})?( \| [0-9A-F]{8}( [0-9A-F]{4})?)*(?<=[0-9A-F]{8} [0-9A-F]{4})$")
HEADING = re.compile(r"^-+\s*(.*?)\s*-+$")
MAX_GROUPS = 15

PDF_TO_TEXT = """
import PDFKit
let d = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
for i in 0..<d.pageCount { print("=== page \\(i+1)"); print(d.page(at: i)?.string ?? "") }
"""


def read_lines(path: Path) -> list[str]:
    if path.suffix.lower() == ".pdf":
        text = subprocess.run(["swift", "-", str(path)], input=PDF_TO_TEXT, text=True,
                              capture_output=True, check=True).stdout
    else:
        text = path.read_text(encoding="utf-8")
    lines = [l.strip() for l in text.splitlines()]
    return [l for l in lines if l and not PAGE_FURNITURE.match(l)]


def display(text: str) -> str:
    """Full-width letters and digits to ASCII (ＨＹＤＬＩＤＥ ２ → HYDLIDE 2)."""
    return unicodedata.normalize("NFKC", text)


def alternatives(line: str) -> list[str]:
    """`D000B5F8 | D000B5F9 F920` → ['D000B5F8 F920', 'D000B5F9 F920'].

    An alternative without its own value shares the last one's, and one with
    a value keeps it (`D0004F48 3195 | D0002808 C195`).
    """
    parts = [p.strip().split() for p in line.split("|")]
    value = parts[-1][1]
    return [p[0] + " " + (p[1] if len(p) > 1 else value) for p in parts]


def parse_groups(body: list[str]) -> tuple[list[str], list[tuple[str, list[str]]]]:
    """Split a game's lines into its notes and its groups.

    A note right under a heading describes that group, and stays with it as a
    `;` line before its codes, where `PATFile.parse` takes it for the group's
    notes. A note under a heading that has no codes leads into the next
    heading (XANADU シナリオ2: "…SUMを調べるので、" / -SUM CHECK PASS- /
    "これを同時に…"), so it moves there. A note after a group's codes is about
    the whole game, so it joins the notes at the top.
    """
    preamble: list[str] = []
    groups: list[tuple[str, list[str]]] = []
    for line in body:
        heading = HEADING.match(line)
        if heading:
            carried: list[str] = []
            if groups and not any(CODE.match(l) for l in groups[-1][1]):
                carried = groups[-1][1][:]
                groups[-1][1].clear()
            groups.append((display(heading.group(1)), carried))
        elif CODE.match(line):
            groups[-1][1].append(line)
        elif not groups or any(CODE.match(l) for l in groups[-1][1]):
            preamble.append("; " + line)
        else:
            groups[-1][1].append("; " + line)
    return preamble, groups


def build_preset(title: str, body: list[str], base: list[str] | None) -> dict:
    preamble, groups = parse_groups(body)
    if base is not None:
        inherited = dict(parse_groups(base)[1])
        groups = [(name, lines if any(CODE.match(l) for l in lines)
                   else lines + [l for l in inherited.get(name, []) if CODE.match(l)])
                  for name, lines in groups]
    assert all(any(CODE.match(l) for l in lines) for _, lines in groups), f"{title}: empty group"

    out = preamble[:]
    names: list[str] = []
    for name, lines in groups:
        counts = {len(alternatives(l)) for l in lines if CODE.match(l) and "|" in l}
        if not counts:
            names.append(name)
            out += [f"# {name}"] + lines
            continue
        assert len(counts) == 1, f"{title} / {name}: alternatives differ in number"
        n = counts.pop()
        labels = VARIANTS.get(title, [f"版{i + 1}" for i in range(n)])
        for i in range(n):
            names.append(f"{name}（{labels[i]}）")
            out.append(f"# {names[-1]}")
            out += [alternatives(l)[i] if CODE.match(l) and "|" in l else l for l in lines]
    assert len(names) <= MAX_GROUPS, f"{title}: {len(names)} groups"
    single = re.compile(r"^[0-9A-F]{8} [0-9A-F]{4}$")
    assert all(single.match(l) for l in out if not l.startswith(("#", ";"))), title
    assert not any("|" in l and l.startswith(";") and re.search(r"[0-9A-F]{8}", l) for l in out), title
    out.append(f"; 出典: {SOURCE}")
    return {"title": display(title), "text": "\n".join(out) + "\n"}


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    lines = read_lines(Path(argv[1]))
    output = Path(argv[2]) if len(argv) > 2 else (
        Path(__file__).resolve().parent.parent / "Bubilator88/Resources/CheatPresets.json")

    starts = []
    for title in TITLES:
        index = lines.index(title, starts[-1] + 1 if starts else 0)
        starts.append(index)
    end = lines.index(END, starts[-1])
    bodies = {title: lines[start + 1:stop]
              for title, start, stop in zip(TITLES, starts, starts[1:] + [end])}
    presets = [build_preset(title, bodies[title], bodies.get(SAME_AS.get(title, "")))
               for title in TITLES]

    output.write_text(json.dumps({"source": SOURCE, "presets": presets},
                                 ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    codes = sum(1 for p in presets for l in p["text"].splitlines() if CODE.match(l))
    print(f"{len(presets)} presets, {codes} codes → {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
