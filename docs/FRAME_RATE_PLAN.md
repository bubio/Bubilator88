# フレームレート実機準拠化 計画

## 1. 背景

Bubilator88 は VSYNC フレームを **60Hz 決め打ち**で回している。実機 PC-8801 の
垂直同期周波数は 60Hz ではなく、モニタの水平周波数 (15kHz / 24kHz) と CRTC
パラメータから決まる **62.4Hz または 55.4Hz** である。XM8 でモニタ種別を
切り替えると表示 fps がこの数字どおりに変わることを実機比較で確認した
(2026-08-07)。

ずれは VRTC 割り込み周期＝ゲームの進行速度・音楽テンポに直結するため、
「動くが実機よりわずかに遅い/速い」という形で全タイトルに効いている。

## 2. 実機仕様

### 2.1 計算式

参照実装 `xm8mac/Source/ePC-8801MA/vm/pc8801/pc88.cpp:2499`:

```cpp
int lines_per_frame = (crtc.height + crtc.vretrace) * crtc.char_height;
double frames_per_sec = (hireso ? 24860.0 * 56.423 / 56.5 : 15980.0)
                        / (double)lines_per_frame;
```

- 水平周波数: 15kHz モニタ = 15,980 Hz / 24kHz モニタ = 24,826.13 Hz
  (`24860 × 56.423 ÷ 56.5` は XM8 が実機実測に合わせた補正値。素の 24,860 では
  ない点に注意)
- `hireso` は `config.monitor_type == 0` (`pc88.cpp:1769`)、すなわち**ユーザ
  設定のモニタ種別**。ソフト側の 400 ライン切替 (port 0x31 bit 0) とは別軸
- `height` / `vretrace` / `char_height` は CRTC (uPD3301) の SET PARAMETER で
  ソフトが書いた値そのもの

### 2.2 モニタ種別ごとの CRTC 既定値

`pc88.cpp:3710-3712` (`pc88_crtc_t::reset(bool hireso)`):

| | char_height | vretrace |
|---|---|---|
| 15kHz | 8 | 7 |
| 24kHz | 16 | 3 |

これは `docs/SPECS/TEXT_VRAM_AND_CRTC.md` 4.1.3 の典型値表 (vraminfo 由来) と
一致する。

### 2.3 結果として得られるフレームレート

| 表示行数 | モニタ | lines/frame | frames/sec |
|---|---|---|---|
| 25 行 | 15kHz | (25+7)×8 = 256 | **62.42 Hz** |
| 25 行 | 24kHz | (25+3)×16 = 448 | **55.42 Hz** |
| 20 行 | 15kHz | (20+6)×10 = 260 | 61.46 Hz |
| 20 行 | 24kHz | (20+2)×20 = 440 | 56.42 Hz |

BubiC の `src/vm/pc8801/pc8801.h:130` にある `#define FRAMES_PER_SEC 62.422`
は 25 行 / 15kHz のケースと一致する。

**重要**: 55Hz 台になるのは 24kHz モニタのときだけであり、15kHz モニタで
55Hz になることはない。24kHz モニタでソフトが 200 ライン表示をしていても
char_height は 16 のままなので 55.4Hz が維持される。

ただしこの「24kHz なら char_height 16」は**ハードウェアの強制ではなくソフト
側の慣習**である。`char_height` はあくまで CRTC の SET PARAMETER でソフトが
書いた値 (`CRTC.swift:441`) であり、`hireso` はリセット時の初期値を決めるだけ
(`pc88.cpp:3710`)。2.2 の表と `docs/SPECS/TEXT_VRAM_AND_CRTC.md` の典型値表が
一致しているのは、当時のソフトが例外なくこの組み合わせを書いていたから。
Phase 2 の式はこの慣習を破るタイトルがあると露出する。

### 2.4 モニタ種別は「スキャンラインの見た目」ではない

15kHz / 24kHz の切替を「走査線を描くかどうか」の表示上の設定と捉えると、
なぜエミュレータのタイミングに関わるのか分からなくなる。XM8 で `hireso` が
参照される箇所は全部で 4 つあり、**描画専用はそのうち 1 つだけ**である。

| 箇所 | 内容 | CPU から見えるか |
|---|---|---|
| `pc88.cpp:3244` | `draw_text` の `char_height <<= 1` | ❌ 描画のみ |
| `pc88.cpp:2502` | `frames_per_sec` の算出 | ✅ VRTC 割り込み周期 |
| `pc88.cpp:1053` | port 0x40 bit 1 (SHG) の応答 | ✅ ソフトが直接読める |
| `pc88.cpp:250` | GVRAM アクセスのウェイト T 数 | ✅ 実行速度が変わる |

#### GVRAM ウェイト

`get_gvram_wait()` (XM8 `pc88.cpp:250` / BubiC `pc88.cpp:2381`)。
ブートモードが V1S / N かつ `Port40_GHSM` (port 0x40 write bit 4) オフ、
かつ表示期間中のときだけモニタ種別で分岐する:

| | 4MHz | 8MHz |
|---|---|---|
| 24kHz | 114 | 141 |
| 15kHz | 68 | 90 |

理由は 88 の映像回路と CPU が GVRAM のバスを共有していること。24kHz は
1 フレームあたりのスキャンライン数が倍なので映像回路のフェッチ時間も長くなり、
その分 CPU が締め出される。つまり実機では **24kHz モニタを繋ぐと CPU の実効
速度が落ちる**。

V1H / V2、あるいは GHSM オンの場合は表示中 2 (4MHz) / 5 (8MHz)、垂直帰線中は
0 / 3 で、モニタ種別に依存しない。Bubilator88 が `Pc88Bus.swift:566-570` で
実装しているのはこちらだけなので、**現時点でこの差は表面化していない**。

> **注意**: XM8 には `update_gvram_wait()` (`pc88.cpp:2517`) という
> `{96,1, 140,3, 232,1, 285,3}` を持つ別実装もあるが、**どこからも呼ばれて
> いない死んだコード**である。実装の根拠にしないこと。

詳細および他のウェイト分類 (M1 / メイン RAM / TVRAM) の実装状況は
`docs/MEMORY_WAIT_STATES.md` を参照。V1S の GVRAM ウェイトに着手する場合は
モニタ種別 (Phase 1) が前提になる。

### 2.5 CPU クロック

実機は **3,993,624 Hz / 7,987,248 Hz** (Bubilator88 は 4.0 / 8.0 MHz 換算で
計算している)。BubiC `src/vm/pc8801/pc8801.h:132` の
`#define CPU_CLOCKS 3993624`、XM8 `pc8801.cpp:94` の
`set_context_cpu(pc88cpu, (config.cpu_type != 0) ? 3993624 : 7987248)` で確認。
T-state 数を実機準拠にするならこちらも基準を合わせる必要がある。

| モニタ | T-states / line (7,987,248Hz) | T-states / frame (25 行) |
|---|---|---|
| 15kHz | 7,987,248 ÷ 15,980 = 499.8 | 499.8 × 256 = 127,956 |
| 24kHz | 7,987,248 ÷ 24,826 = 321.7 | 321.7 × 448 = 144,132 |

4MHz モードはいずれも半分。

## 3. Bubilator88 の現状とのずれ

### 3.1 フレーム長が定数

`Packages/EmulatorCore/Sources/EmulatorCore/Machine.swift:202`:

```swift
public var tStatesPerFrame: Int {
  clock8MHz ? 133_333 : 66_667  // 8MHz/60Hz or 4MHz/60Hz
}
```

`133_333 = 8,000,000 ÷ 60`。CRTC の状態に一切依存しない。

### 3.2 しわ寄せがライン時間に出ている

`Machine.swift:223` は `tStatesPerFrame ÷ crtc.dynamicTotalScanlines` で
1 ライン時間を求めるため、**フレームが 60Hz に固定されたまま水平周波数の方が
歪む**。

| モード | 本機 | 実機 | 差 |
|---|---|---|---|
| 200 ライン (262 本) | 133,333/262 = 508.9 T → 15.72 kHz | 15.98 kHz | −1.6% |
| 400 ライン (448 本) | 133,333/448 = 297.6 T → 26.88 kHz | 24.83 kHz | +8.2% |

ライン単位のタイミングを見るソフト (ラスタ割り込み相当の処理、VRTC ポーリング
によるウェイト) は 400 ライン時に特に影響を受ける。

### 3.3 モニタ種別という概念がない

`Packages/EmulatorCore/Sources/EmulatorCore/Pc88Bus.swift:788-792`、port 0x40
読み出しの bit 1 (SHG):

```swift
// bit 1: SHG — monitor type (hardware config).
// XM8: hireso ? 0 : 2. QUASI88: HIGH_MODE ? 0 : 2.
// PC-8801-FA has 24kHz monitor (hireso) → bit 1 = 0.
// 15kHz monitor → bit 1 = 1 (0x02).
return value
```

コメントに仕様は書かれているが、**実際にはどの経路でも 0x02 を立てていない**。
ソフトから見ると常に 24kHz モニタと報告される。仕様は
`docs/SPECS/IO_PORT_MAP.md:180` (`bit 1 SHG: 0=24kHz, 1=15kHz`) に記載済み。

### 3.4 CRTC リセット値が 15kHz/24kHz どちらとも違う

`Packages/EmulatorCore/Sources/Peripherals/CRTC.swift:247-262`:

```swift
linesPerScreen = 25
charLinesPerRow = 8
...
vretrace = 1
```

XM8 の `reset(hireso)` は 15kHz で `char_height=8, vretrace=7`、24kHz で
`char_height=16, vretrace=3`。`vretrace = 1` はどちらでもない。ソフトが SET
PARAMETER を発行するまでの短い期間だけ効くが、フレーム長を CRTC 由来にすると
この初期値がそのまま起動直後のフレームレートになるため無視できなくなる。

なお `charLinesPerRow` / `vretrace` は `CRTC.swift:441,446` で実レジスタから
正しく復元されているので、**計算に必要な材料はすでに揃っている**。

### 3.5 200 ライン時の総スキャンライン数が NTSC 値

`CRTC.swift:29`:

```swift
public static let totalScanlines200 = 262
```

262 は NTSC 由来の値で、PC-8801 の (25+7)×8 = 256 とは異なる。`mode200Line`
が true のときは CRTC パラメータを無視してこの定数を使う
(`CRTC.swift:50-52`)。実機準拠にするならこの分岐自体が不要になる。

## 4. 実装計画

### Phase 1 — モニタ種別のモデル化

- `Machine` / `Pc88Bus` に `monitorType: MonitorType { case khz15, khz24 }` を追加
- port 0x40 bit 1 (SHG) を `monitorType` から返す (`Pc88Bus.swift:788`)
- `CRTC.reset()` を `reset(monitorType:)` 相当にし、`charLinesPerRow` /
  `vretrace` の初期値を 2.2 の表に合わせる
- リセット時にのみ反映 (XM8 と同じく実行中の動的変更はしない)

デフォルト値は要検討 (§6)。

### Phase 2 — フレーム長を CRTC 由来にする

- `Machine.tStatesPerLine` を「CPU クロック ÷ 水平周波数」の一次量に反転
- `Machine.tStatesPerFrame` を `tStatesPerLine × crtc.dynamicTotalScanlines`
  の導出量にする
- CPU クロック基準を 8,000,000/4,000,000 → 7,987,248/3,993,624 へ。これは
  `tStatesPerFrame` だけでなく **`Machine.swift:233` の `tStatesPerRTC`**
  (`13_333 / 6_667` = 8,000,000 ÷ 600) にも及ぶ。600Hz RTC ティックを
  取りこぼさないよう同時に直すこと
- `CRTC.dynamicTotalScanlines` の 200 ライン特例 (262 固定) を撤去し、常に
  `(linesPerScreen + vretrace) × charLinesPerRow` にする

262 固定を外す際は、その clamp が何を防いでいたのかを必ず引き継ぐこと。
`CRTC.swift:42-43` に理由が明記されている:

> Guard: if mode200Line=false but CRTC params are still for 200-line mode,
> the formula gives ~208 which breaks VRTC timing. Clamp to >= 262.

つまり「ソフトが port 0x31 で 400 ライン化した直後、CRTC の SET PARAMETER が
まだ 200 ライン用のまま」という過渡状態が実在し、そこで素の式を使うと約 208
という無効な値になって VRTC タイミングが壊れる。Phase 2 はこの窓を再び開ける
ので、下限クランプか「CRTC 未初期化なら前回値を保持」といった等価の防御を
入れ、コメントでこの経緯を残す。この知見は `docs/KNOWN_PITFALLS.md` にも
1 項目として追加する (AGENTS.md の「Hardware findings are documentation」)。

この時点で VRTC 割り込み周期が実機準拠になる。

### Phase 3 — 描画ループとの整合

`Bubilator88/Rendering/EmulatorMetalView.swift:433-457` の draw ループは
すでに `emulatedTime` / `realElapsed` の実時間アキュムレータを持っている:

```swift
private let frameInterval: CFTimeInterval = 1.0 / 60.0
...
if emulatedTime <= realElapsed {
  viewModel.emuQueue.sync { viewModel.runFrameForMetal(frameCount: framesPerDraw) }
  emulatedTime += frameInterval
}
```

`frameInterval` をマシンの現在のフレーム長由来の値にするのが第一歩だが、
**それだけでは 62.42Hz に到達できない**。

`EmulatorMetalView.swift:73` で `preferredFramesPerSecond = 60`、そして上記は
`while` ではなく `if` なので、**1 draw につきマシンフレームは高々 1
(正確には `framesPerDraw`) 個**しか進まない。上限は 60 フレーム/秒である。

- **24kHz (55.42Hz) 方向は問題ない。** 必要フレーム数が 60 未満なので、
  1 秒あたり数回 draw が空振りする (= 同じ画面を再提示する) だけで済む。
  これは実機の挙動としても正しい
- **15kHz (62.42Hz) 方向が壊れる。** 毎秒 2.42 フレーム、時間にして約 0.039
  秒ずつ遅れが溜まり、約 13 秒ごとに
  `realElapsed - emulatedTime > 0.5` のキャッチアップ保護
  (`EmulatorMetalView.swift:454`) が発火して約 31 フレーム分を無音でスキップ
  する。周期的な時間跳躍と音声の不連続として出る

§7 の推奨どおり既定を `.khz15` にするなら、こちらが本命の経路である。よって
Phase 3 では:

1. `if` を**上限付きの `while`** に変える (1 draw で複数マシンフレームを
   消化できるようにする。暴走防止の上限は必須)
2. `framesPerDraw` との相互作用を整理する。これは既に
   「1 `frameInterval` あたり N マシンフレーム」という速度倍率の意味を持つ
   ので、`while` の反復回数と掛け算になる関係を明示すること
3. あるいは `preferredFramesPerSecond` をディスプレイのリフレッシュレートに
   追従させる案もあるが、120Hz 環境と 60Hz 環境で挙動が変わるため
   `while` 化の方が素直

音声は `Machine.swift:464` などで `sound.tick(tStates:)` により T-state 駆動
なので、フレーム長が変わればサンプル数も自動追従する。60Hz 前提の箇所はない。

### Phase 4 — 永続化と UI

- `monitorType` を設定項目として追加 (リセットで反映される旨の注記が要る)
- `SaveStateSerialize.swift` に `monitorType` を追加 → セーブステートの
  フォーマット変更。既存 `.b88s` の読み込み互換をどうするか要検討
- FPS 表示が 55/62 になるので、UI 上で「異常ではない」と分かる見せ方を検討

## 5. 影響とリスク

- **VRTC 割り込みで駆動されるゲームロジックの速度が変わる**。15kHz 設定なら
  約 +4% (60 → 62.42Hz)、24kHz 設定なら約 −8% (60 → 55.42Hz)。スクロール、
  キャラクタ移動、ウェイトループなどが該当する
- **音楽テンポはほぼ影響を受けない**。PC-88 の FM ドライバは大半が YM2608 の
  Timer A/B でテンポを取っており、`sound.tick(tStates:)` (`Machine.swift:464`)
  は実時間あたり一定レートの T-state 駆動なので、フレーム長を変えても動かない。
  動くのは 8,000,000 → 7,987,248 のクロック基準変更ぶんの **0.16% だけ**で
  可聴域ではない。regression の目視分類でテンポ差を探しに行かないこと
  (逆に、VRTC でテンポを取っている少数のドライバがあれば +4%/−8% 側に出る)
- **regression のベースラインが全面的に無効化される**。16 シナリオ
  (`scripts/capture_reference_screenshots.py` の `SCENARIOS`) を全て再取得し、
  差分は 1 件ずつ目視分類が必要
- `Packages/EmulatorCore/Tests/EmulatorCoreTests/MachineTests.swift:150,154` が
  `tStatesPerFrame == 133_333 / 66_667` をハードコードで assert しており失敗する
- `Mode400LineTests.swift:136` / `CRTCTests.swift:22` などの
  `tStatesPerLine = 297 / 509` も同様に更新が必要
- セーブステート互換 (Phase 4)
- BootTester (`Sources/BootTester/main.swift:770,1042,1534`) はフレーム境界を
  `tStatesPerFrame` から算出しているので導出量への変更に自動追従するが、
  ブート完了までのフレーム数が変わるため各シナリオの待ちフレーム数の見直しが
  要るかもしれない

## 6. 未確定事項

1. **`monitorType` の既定値をどちらにするか。** 現状の port 0x40 は常に
   24kHz と報告しているので、そのまま `.khz24` を既定にすると全タイトルが
   55.4Hz になり体感速度が落ちる。

   なお実機ではモニタ種別は **DIP SW1 bit 8「CRT モード」**
   (`docs/SPECS/DIP_SWITCH.md:19`、ON=専用ディスプレイ 24.8kHz /
   OFF=標準ディスプレイ 15.7kHz) であり、独立した設定項目ではなく DIP の
   1 ビットとして持たせるのが実機に忠実。port 0x40 read bit 1 (SHG) は
   その読み戻し口にあたる。

   `.khz15` を既定にするのが妥当と考えており、根拠は参照実装 2 本が揃って
   15kHz 既定であること:
   - BubiC の `FRAMES_PER_SEC 62.422` (`pc8801.h:130`) は 25 行 / 15kHz の値
   - QUASI88 は `HIGH_MODE` を立てたときだけ 24kHz 扱い
     (`Pc88Bus.swift:790` のコメントが引用している)

   ただし SHG bit の応答が 0 → 0x02 に変わるので、これを見るソフトの挙動確認が
   必要 (§6.2 参照)。

2. **15kHz + 400 ライン という実機に存在しない組み合わせをどう扱うか。**
   実機で 400 ライン表示には 24kHz モニタが要る。既定を `.khz15` にすると、
   ソフトが port 0x31 bit 0 で 400 ライン化したときに
   「15kHz なのに 400 ライン」という状態が作れてしまう。決めるべきこと:
   - `dynamicTotalScanlines` が何を返し、フレームレートが何 Hz になるのか
   - 描画側との整合。`EmulatorViewModel+Rendering.swift:186` と
     `BootTester/main.swift:388` は**どちらも `hireso: true` をハードコード**
     しており、現時点で描画パスとモニタ種別軸はすでに食い違っている
   - SHG bit を見てから 400 ライン化を判断するソフトは、`.khz15` 既定では
     「24kHz ではない」と答えられることになる。これが §6.1 で言う挙動確認の
     具体的な中身であり、regression で最優先に見るべき点
3. **`24860 × 56.423 ÷ 56.5` の出典。** XM8 のこの補正の根拠が未確認。BubiC も
   同じ式を持つ (`src/vm/pc8801/pc88.cpp:2248`) ので XM8 由来と思われる
4. **Phase 2 だけ先に入れて Phase 1 を後回しにできるか。** 現状の
   「常に 24kHz と報告」を維持したまま CRTC 由来にすると 55.4Hz 側に倒れる。
   Phase 1 と 2 はセットで入れる方が安全
5. **cpuOverclock (`Machine.swift:215`) との相互作用。** 「CRTC・音源は実速度、
   CPU だけ N 倍」という前提はフレーム長が可変になっても崩れないはずだが、
   要検証

## 7. 進め方の提案

Phase 1 + 2 を別ブランチで実装し、`monitorType = .khz15` (62.42Hz) の状態で
regression を回して差分を目視分類する。ここで「速くなっただけ」以外の破綻が
出ないことを確認してから Phase 3 / 4 に進む。

Phase 3 を後回しにできるのは、regression が BootTester (ヘッドレス) 経由で
あり、`Sources/BootTester/main.swift:770` などの独自ループが
`tStatesPerFrame` を直接使っていて Metal の draw ループを通らないため。
逆に言うと **Phase 3 前の GUI 実行は 62.42Hz を正しく再生できない**ので、
この段階での体感確認は 24kHz 設定 (55.42Hz) 側でしか成立しない。

## 参照

- `xm8mac/Source/ePC-8801MA/vm/pc8801/pc88.cpp` — `hireso` の全参照箇所:
  `1053` (SHG), `1769` (設定読み込み), `2499-2508` (フレームレート),
  `2531` (GVRAM ウェイト), `2756` / `3244` (描画), `3700-3712` (CRTC リセット値)
- `xm8mac/Source/ePC-8801MA/vm/pc8801/pc8801.cpp:94` (CPU クロック)
- `BubiC-8801MA/src/vm/pc8801/pc8801.h:130-131`,
  `src/vm/pc8801/pc88.cpp:2245-2253`
- `docs/SPECS/TEXT_VRAM_AND_CRTC.md` 4.1.3 (CRTC パラメータ典型値)
- `docs/SPECS/IO_PORT_MAP.md:180` (port 0x40 bit 1 SHG)
