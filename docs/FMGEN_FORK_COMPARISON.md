# fmgen 派生版の比較 — rururutan/m88 系のパッチと Bubilator

Bubilator の FM 合成コアは cisc 氏の fmgen を Swift へ移植したものだが
(移植元と改変内容は `Packages/EmulatorCore/Sources/FMSynthesis/fmgen-changes.md`)、
fmgen には複数の派生版があり、それぞれ独自の修正を抱えている。

本ドキュメントは、そのうち rururutan 氏の m88 系に入っている修正を洗い出し、
Bubilator の実装と突き合わせた記録である。**すべてコード読みによる判定**で、
音の実測比較は行っていない (実測したのは PG アンダーフローの 1 件のみ)。

調査日: 2026-08-05

## きっかけ

ザナドゥ シナリオ2 レベル4 の BGM で、実機だけが鳴らす「キーン」という高音が
再現できない問題を追ったところ、原因は F-Number 0 書き込み時の位相増分の
アンダーフローだった (PR #99)。素の fmgen は無音になるが、M88M では鳴ることが
判明したため、m88 系に他にどのような修正があるのかを調べた。

## 前提: M88M 独自の音源パッチは正味ゼロ

M88M (m88 の macOS 移植) には音源系のコミットが 4 件あるが、実質的な差分は
残っていない。

| コミット | 日付 | 内容 | 顛末 |
|---|---|---|---|
| `4436079` | 2026-04-29 | ADPCM 開始アドレスの条件付き更新、`strncpy` 安全化、`fsize` の `Max`→`Min` 修正、`delete[]` 修正 | ADPCM 部分は翌日撤回 |
| `2ee6ec0` | 2026-04-30 | 上記 ADPCM 変更を revert | — |
| `d7ddf41` | 2026-04-30 | リズム/PSG を「オリジナルのコードに戻した」 | — |
| `76004bd` | 2026-05-03 | 行末空白のみ (75/75 行) | 実質無変更 |

したがって比較対象は上流 [rururutan/m88](https://github.com/rururutan/m88) の
8 コミットに集約される。

## m88 の fmgen パッチと Bubilator の対応

| # | コミット | 内容 | Bubilator | 判定に使ったシンボル |
|---|---|---|---|---|
| 1 | `eafbaaa` | LFO PM テーブルの `pmtable[c] = v` (自己代入バグ修正)、初期化漏れ群 | 取り込み済 | `pmWaveformTable` が `c*2+0x80` / `0x7F-(c-0x40)*2+0x80` / `(c-0xC0)*2` で修正後と一致 |
| 2 | `60ff98f` | 効果音モードと CSM 同時指定時の TL ゲート `(regtc & 0xC0) == 0x80` | **未取り込み** | `csmModeEnabled` = `(registers[0x27] & 0x80) != 0` — bit6 を見ていない |
| 3 | `414d16b` | SSG-EG 使用時の `EGUpdate()` 位置を switch の外へ | **未取り込み** | `egCalc()` は `if egLevel >= egLevelOnNextPhase` の内側先頭で `egUpdate()` = 修正前の形 |
| 4 | `595bb03` | PG 演算精度向上 (XM7 由来) | 取り込み済 | `pgDiff >>= (2 + ratioBits - phaseBits)` + `makeMultable` の `rr = dt2Multiplier[h] * Float(ratio)` |
| 5 | `c923ec7` | `*p++ = p[-512]/2` の未定義動作修正 | 非該当 | Swift は明示インデックス |
| 6 | `1e7aa9b` | PG オーバーフロー対策 | 独自方式で対応 (PR #99) | クランプではなく 18bit ラップ |
| 7 | `374abbd` | ADPCM 開始アドレス書き込み時に再生アドレスを更新しない | **未取り込み** | `handleExtRegisterWrite` の `case 0x02, 0x03:` で `adpcmMemAddr = adpcmStartAddr << 6` を実行 |
| 8 | `1c48d83` | SSG-EG と CSM を XM7 実装に置換 (190 行) | **未取り込み** | `ssgEnvelopeTable` の `(ssgType*12)+(m*6)+(phase*2)` 添字と 56/60 閾値 = 旧 `ssgenvtable` 形式。`EGPhase` に `hold` なし、`KeyOnCsm` 相当なし |

#4 の XM7 由来の改良は XM8 や common source project 系にも入っているため、
Bubilator にあるのが m88 経由とは限らない。

## PG アンダーフローの扱いの違い (#6)

同じ現象に対して手法が異なる。

- **m88**: 負になったら `0x3FF80` (2047<<7) に固定クランプ → 常に 6930.2 Hz
- **Bubilator**: 18bit マスクでラップ → DT1 の値に応じて 6930.6〜6933.0 Hz

実機録音では 6931.6 Hz。どちらも誤差 0.02% 以内で聴感上の差はない。ラップの方が
実機の 17bit 加算器の挙動そのままで、DT1 の値によって周波数が僅かに変わる点まで
一致する。

## 未取り込み 3 領域の影響

1. **SSG-EG / CSM** (#3, #8 — #8 が #3 を含んで書き直しているため実質ひと続き)
   Bubilator の SSG-EG は 2020 年以前の fmgen の形。影響するのは SSG-EG を
   使った音色と、AR が 31 未満のときの挙動。fmgen 自身のコメントが
   「AR!=31 で SSGEC を使うと波形が実機と異なる可能性」と認めている箇所。

2. **ADPCM 開始アドレス** (#7)
   KAJA 氏の指摘 (https://twitter.com/kajaponn/status/1292470271295668224) を
   受けた修正。開始アドレスレジスタを書いただけで再生位置が飛ぶかどうかの違いで、
   サウンドボード II の ADPCM 再生タイミングに影響しうる。M88M が一度条件付きで
   戻して即撤回しているため、上流 m88 ではコメントアウトされた状態が現状。

3. **CSM / 効果音モード同時指定** (#2)
   レジスタ 0x27 の bit6 と bit7 を同時に立てたときだけの差。使用例は限られる。

いずれも取り込むかは未定。特に #8 は 190 行の書き換えで、`prepare()` は全 FM
オペレータのホットパスにあたるため、着手する場合は相応の回帰確認が必要になる。
