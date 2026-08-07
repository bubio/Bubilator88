# PC-8801 メモリウェイト仕様と実装状況

PC-8801 の CPU はメモリアクセスのたびに、アクセス先と機体設定に応じた
ウェイト T-state を挿入される。本書は参照実装 (BubiC / XM8) のウェイトモデル
全体と、Bubilator88 での実装状況・未実装箇所を対照する。

フレームレートの実機準拠化とは独立したテーマだが、GVRAM ウェイトだけは
モニタ種別 (15kHz / 24kHz) に依存するため `docs/FRAME_RATE_PLAN.md` §2.4 と
接続する。

## 1. なぜウェイトが要るか

GVRAM (0xC000-0xFFFF の 3 プレーン) と TVRAM (0xF000-0xFFFF) は、CPU と映像
回路が同じメモリを共有している。映像回路は画面表示中ずっと VRAM を読み出して
ドットを吐き続けるので、そこへ CPU がアクセスすると **バスが空くまで CPU が
WAIT で止められる**。

したがって同じ `LD A,(HL)` でも、
- 垂直帰線中の GVRAM: ほぼ待たされない
- 表示中の GVRAM (V1S モード): 数十〜百数十 T-state 待たされる

という桁違いの差が出る。「VRTC を待ってから一気に GVRAM へ書く」という
PC-88 ゲームの定石はこれが理由であり、
`docs/SPECS/TEXT_VRAM_AND_CRTC.md:410` の `WaitVBlank` ループが実例。

ウェイトを実装しないエミュレータは実機より速く動くため、速度に依存した
ソフト (ローディング中のアニメーション、タイミング調整、プロテクト) が
実機と違う挙動になる。

## 2. 参照実装のウェイトモデル

BubiC `src/vm/pc8801/pc88.cpp:2286-2470` と XM8
`Source/ePC-8801MA/vm/pc8801/pc88.cpp:250-370`。両者は同一の数値モデル
(コメントいわく "XM8 version 1.20") を持つ。ウェイトは 4 分類:

| 関数 | 対象 |
|---|---|
| `get_m1_wait()` | オペコードフェッチ (M1 サイクル) |
| `get_main_wait()` | メイン RAM / ROM |
| `get_tvram_wait()` | TVRAM (0xF000-0xFFFF) |
| `get_gvram_wait()` | GVRAM (0xC000-0xFFFF) |

### 2.1 M1 ウェイト (`get_m1_wait`)

| 条件 | 4MHz | 8MHz |
|---|---|---|
| V1S / N + メモリウェイト DIP off | +1 | 0 |
| V1H / V2 + DIP off + 0xF000 台 (TVRAM) かつ `!gvram_sel && !Port32_TMODE` | +1 | 0 |
| それ以外 | 0 | 0 |

### 2.2 メイン RAM / ROM ウェイト (`get_main_wait`)

| 条件 | ウェイト |
|---|---|
| 4MHz + メモリウェイト DIP on + read | +1 |
| 4MHz + それ以外 | 0 |
| 8MHz (8MHzH でない機種) | +1 |
| 8MHz + メモリウェイト DIP on | さらに +1 (read/write 両方) |

### 2.3 TVRAM ウェイト (`get_tvram_wait`)

| 条件 | ウェイト |
|---|---|
| 4MHz + read + メモリウェイト DIP on | +1 |
| 4MHz + write | 0 |
| 8MHz + read | +2 |
| 8MHz + write | +1 |

8MHz では DIP の状態に関係なく固定 (コメント: "memory wait do not effect")。

### 2.4 GVRAM ウェイト (`get_gvram_wait`)

**グラフィック表示 ON (`Port31_GRAPH`)**:

| 条件 | 4MHz | 8MHz |
|---|---|---|
| V1S/N + GHSM off + 表示中 + **24kHz** | **114** | **141** |
| V1S/N + GHSM off + 表示中 + **15kHz** | **68** | **90** |
| 上記以外 (V1H/V2、または GHSM on) + 表示中 | 2 | 5 |
| 垂直帰線中 | 0 | 3 |

**グラフィック表示 OFF**:

| 条件 | ウェイト |
|---|---|
| 4MHz + メモリウェイト DIP on + read | +1 |
| 4MHz + それ以外 | 0 |
| 8MHz | +3 |

V1S / N モードで GHSM がオフのときだけ桁が変わる。通常のメモリ read が
数 T-state であることを考えると 90 T-state は **20 倍以上**であり、
V1S 対応ソフトのグラフィック描画速度を決定づける。

24kHz は 15kHz の約 1.57 倍 (90 → 141)。映像回路がバスを掴んでいる時間が
長いことによると思われるが、スキャンライン数は倍なのに待ち時間は 1.57 倍
なので単純な比例ではない。この比率の根拠となる一次資料は未確認。

### 2.5 ウェイトを決める入力

| 入力 | 出所 |
|---|---|
| CPU クロック 4/8MHz | 機体設定 |
| ブートモード V1S / N か V1H / V2 か | DIP SW3-S0 (port 0x31 read bit 6) |
| メモリウェイト DIP | **DIP SW1 bit 6** (`docs/SPECS/DIP_SWITCH.md:17`) |
| `Port31_GRAPH` (グラフィック表示) | port 0x31 write bit 3 |
| `Port40_GHSM` (グラフィックハイスピード) | port 0x40 write bit 4 |
| `crtc.vblank` | CRTC の垂直帰線状態 |
| `hireso` (モニタ 15/24kHz) | **DIP SW1 bit 8** (`docs/SPECS/DIP_SWITCH.md:19`)、port 0x40 read bit 1 (SHG) で読み戻せる |

### 2.6 XM8 の `update_gvram_wait()` は死んでいる (要注意)

XM8 `pc88.cpp:2517` に `update_gvram_wait()` という別実装があり、

```cpp
// from memory access test on PC-8801MA2
static const int wait[8] = {96,1, 140,3, 232,1, 285,3};
```

という一見もっともらしい実測テーブルを持っている。**しかしこの関数は
XM8 のどこからも呼ばれていない** (`grep -rn update_gvram_wait` の結果は
宣言と定義のみ)。`gvram_wait_clocks_r/w` もセーブステートの読み書きに
現れるだけである。

生きているのは §2.4 の `get_gvram_wait()` (68/90/114/141) の方。ePC-8801MA
から引き継いだ旧実装が残っているだけなので、**96/140/232/285 を実装の根拠に
してはいけない**。BubiC 側は `update_gvram_wait()` が
`get_gvram_wait()` を呼ぶ構造 (`pc88.cpp:2476-2479`) になっており、
こちらは生きている。

## 3. Bubilator88 の実装状況

実装は `Packages/EmulatorCore/Sources/EmulatorCore/Pc88Bus.swift` の
`memRead` / `memWrite` に直接埋め込まれ、`pendingWaitStates` に加算される。
`Machine.swift:458-459` が CPU ステップごとに読み出してクリアする。

| 分類 | 状況 |
|---|---|
| M1 ウェイト | ❌ **未実装** (オペコードフェッチを区別していない) |
| メイン RAM / ROM ウェイト | ⚠️ 簡略実装 |
| TVRAM ウェイト | ⚠️ 8MHz のみ実装 (read +2 / write +1) |
| GVRAM ウェイト V1H/V2 経路 | ✅ 実装済み |
| GVRAM ウェイト V1S/N 経路 | ❌ **未実装** |

### 3.1 実装済み: GVRAM の V1H / V2 経路

`Pc88Bus.swift:566-570` (read) と `:642-646`, `:664-668` (write):

```swift
// BubiC V1H/V2 8MHz: active+graphOn=5T, vblank/graphOff=3T
if cpuClock8MHz {
  pendingWaitStates += vrtcFlag ? 3 : (graphicsDisplayEnabled ? 5 : 3)
} else {
  if !vrtcFlag && graphicsDisplayEnabled { pendingWaitStates += 2 }
}
```

§2.4 の 3 行目・4 行目 (2/5/0/3) とグラフィック OFF 8MHz の +3 に一致する。

### 3.2 未実装: GVRAM の V1S / N 経路

68 / 90 / 114 / 141 のテーブルが存在しない。したがって **V1S モードの
タイトルは実機よりグラフィック描画が 20 倍近く速く回っている**。

必要な前提が 2 つとも未整備:

- **GHSM (port 0x40 write bit 4) を見ていない。** `Pc88Bus.swift:1010` で
  `port40w` に値は保存しているので `port40w & 0x10` で取れるが、ウェイト
  計算に使っていない
- **モニタ種別 (15/24kHz) がない。** `docs/FRAME_RATE_PLAN.md` §3.3 のとおり、
  port 0x40 read bit 1 (SHG) は常に 24kHz を返しており設定軸自体が存在しない

### 3.3 簡略実装: メイン RAM とモード判定の混同

`Pc88Bus.swift:230`:

```swift
public var v1sMemWait: Bool { (dipSw2 & 0x40) == 0 }
```

これは DIP SW3-S0 (`docs/SPECS/DIP_SWITCH.md:59`、0=スタンダード V1S /
1=ハイスピード V1H/V2) であり、**ブートモードの軸**である。

一方 BubiC / XM8 は `config.boot_mode` (V1S/N か否か) と `mem_wait_on`
(DIP SW1 bit 6 のメモリウェイト) を**独立した 2 軸**として扱う。
Bubilator88 は後者を持たず、`v1sMemWait` 1 本で両方を兼ねている。

実際の加算も参照実装と形が違う。`Pc88Bus.swift:487-488` (read):

```swift
if cpuClock8MHz { pendingWaitStates += 1 }
if v1sMemWait { pendingWaitStates += 1 }  // V1S read wait
```

§2.2 の `get_main_wait()` は「8MHz なら +1、さらに DIP on なら +1」で、
4MHz の read は DIP on のときだけ +1。Bubilator88 は 4MHz でも `v1sMemWait`
なら read/write を問わず +1 する。近いが同じではない。

なお write 側 (`:603-606`) は 8MHz のときしか加算しないので、4MHz の
`v1sMemWait` は read だけに効く。結果的に §2.2 の 4MHz 行に近い形になって
いるが、意図した一致かは不明。

### 3.4 未実装: M1 ウェイト

オペコードフェッチと通常のメモリリードを区別していないため、§2.1 は
まったく反映されていない。影響は 4MHz + V1S/N + メモリウェイト DIP off の
組み合わせに限られる。

## 4. 未実装の影響

- **V1S タイトルのグラフィック描画が実機より大幅に速い。** 速度依存の演出
  (フェード、ワイプ、ラスタ風の書き換え) が実機と違って見える可能性
- `docs/KNOWN_PITFALLS.md:185` の調査履歴が示すとおり、V1H メモリ wait は
  過去に実際の起動不具合の真因になっている。ウェイト層は「動く/動かない」に
  効く
- ただし **ウェイト精度を検証する項目は現行の regression スイートに含まれて
  いない** (`scripts/capture_reference_screenshots.py` の `SCENARIOS` はいずれも
  起動後の画面 pixel 比較)。したがって未実装であることが自動検出される
  経路はなく、逆に言えば実装しても既存スイートでは正しさを確認できない

## 5. 実装するなら

依存順:

1. **モニタ種別 (15/24kHz) の導入** — `docs/FRAME_RATE_PLAN.md` Phase 1 と
   共通の前提。DIP SW1 bit 8 が出所なので、DIP として持たせるのが素直
2. **GHSM (port 0x40 write bit 4) をウェイト計算に接続** — 値自体は
   `port40w` にある
3. **メモリウェイト DIP (SW1 bit 6) を `v1sMemWait` から分離** — ブート
   モード軸とメモリウェイト軸を独立させる。既存挙動が変わるので regression
   必須
4. **`get_gvram_wait()` 相当への置き換え** — §2.4 の表をそのまま実装
5. **M1 ウェイト** — バスに「オペコードフェッチである」ことを伝える経路が
   必要で、Z80 コアの改修を伴う。費用対効果は最も低い

1〜4 は独立した PR に分けられる。3 は既存タイトルの挙動が動くので単独で
regression を回すこと。

## 参照

- `BubiC-8801MA/src/vm/pc8801/pc88.cpp:2286-2479`
  (`get_m1_wait` / `get_main_wait` / `get_tvram_wait` / `get_gvram_wait`)
- `xm8mac/Source/ePC-8801MA/vm/pc8801/pc88.cpp:250-370` (同等の pattern 版)、
  `:2517-2549` (**呼ばれていない旧実装**)
- `Packages/EmulatorCore/Sources/EmulatorCore/Pc88Bus.swift:230,483-716`
- `docs/SPECS/DIP_SWITCH.md` (SW1 bit 6 メモリウェイト / bit 8 CRT モード、
  SW3-S0 スタンダード/ハイスピード)
- `docs/SPECS/IO_PORT_MAP.md:165` (port 0x40 write bit 4 GHSM)
- `docs/FRAME_RATE_PLAN.md` §2.4 (モニタ種別が CPU から見える経路)
