# Bubilator88 デバッガ リファレンス

Debug Window の全機能と実装の概要。デバッグ作業の手引きとして使う。

---

## 1. 概要

Debug Window は **DEBUGメニュー → Open Debug Window** (または対応するメニューキー) で開く。  
ウィンドウを閉じると `DebugSession.stop()` が呼ばれ、ポーリングが止まり、オーディオミュートがリセットされる。再度開くと新しい `DebugSession` が作られ、デバッガは引き続き動作する。

SwiftUI の `Window` シーンで実装されている。かつて `UtilityWindow` を使っていたが、これは NSPanel + `.nonactivatingPanel` で key ウィンドウにならず、クリックしてもタイトルバーが常に薄い「非アクティブ」表示のままになる問題があった。通常の `Window` に変更してクリックで key になるようにしている。

```
┌────────────────────────────────────────────────────────┐
│  [Run] [Pause] [Step] [Step Sub]     ◉ Running  T: …  │  ← ツールバー
├──────────────┬──────────────────┬──────────────────────┤
│ Disassembly  │   Register       │   Breakpoint         │  ← 上段 (HSplit)
│              │                  │                      │
├──────────────┴──────────────────┴──────────────────────┤
│ [Memory] [Trace] [PIO] [GVRAM] [Text] [Audio]          │  ← 下段 TabView
│                                                        │
└────────────────────────────────────────────────────────┘
```

---

## 2. 実装構造

### App 層 (`Bubilator88/Views/Debug/`)

| ファイル | 役割 |
|---------|------|
| `DebugView.swift` | ルートビュー。`DebugSession` のライフサイクル管理、ツールバー |
| `DebugSession.swift` | スナップショットポーリング、Run/Pause/Step、GVRAM/TextVRAM キャプチャ |
| `DebugSettings.swift` | デバッグUI設定の永続化 (`@Observable`, UserDefaults) |
| `MachineSnapshot.swift` | ポーリング結果の値型 (register + disasm + hex window) |
| `*Pane.swift` | 各タブ/ペインのビュー |

### EmulatorCore 層 (`Packages/EmulatorCore/Sources/EmulatorCore/Debugger/`)

| ファイル | 役割 |
|---------|------|
| `Debugger.swift` | `@Observable` デバッガ本体。ブレークポイント管理、トレース ring buffer、PIO フローログ |
| `Breakpoint.swift` | `Breakpoint` 値型。6種類の Kind と値フィルタ |
| `InstructionTrace.swift` | `InstructionTraceEntry` 値型 (PC + 全レジスタ) |
| `InstructionTraceJSONL.swift` | トレースの JSONL 出力フォーマット |
| `PIOFlowLog.swift` | `PIOFlowEntry` 値型 + `PIOFlowJSONL` 出力フォーマット |
| `Disassembler.swift` | Z80 逆アセンブラ (DisassemblyPane が使用) |

### スレッドモデル

`Debugger` は `emuQueue` (エミュレータスレッド) と Main スレッド (UI) の両方から使われる。内部で `NSLock` によるミューテックスで全ミュータブル状態を保護している。`Machine` 自体は `@unchecked Sendable` として宣言されており `emuQueue` 専用アクセスが前提。

---

## 3. ツールバー

| ボタン | ショートカット | 動作 |
|--------|--------------|------|
| **Run** | — | ポーズ状態から再開。`viewModel.resume()` 経由で Metal + Audio も再開 |
| **Pause** | — | 実行中に一時停止。`viewModel.pause()` 経由 |
| **Step** | — | メイン CPU を1命令だけ実行。ポーズ中のみ有効 |
| **Step Sub** | — | サブ CPU を1命令だけ実行。ポーズ中のみ有効 |
| **Refresh** | — | スナップショットを即時更新 (通常は自動更新) |

ツールバー中央の **実行状態バッジ**: 緑 (Running) / オレンジ (Paused) + 累積 T ステート数を表示。

---

## 4. 上段ペイン

### 4.1 Disassembly ペイン

- メイン CPU / サブ CPU を **CPU Picker** で切り替え。切り替えは `DebugSession.focusedCPU` に反映される
- ポーズ時は現在 PC を中心に ±8 バイトの逆アセンブル結果を表示
- **Trace ペインの行をクリック**すると、その PC に Disassembly ビューがジャンプ (ピン留め) される

#### ヘッダのコントロール

| コントロール | 動作 |
|------------|------|
| ▶/⏸ トグル | **逆アセンブル ON/OFF**。OFF 時は 128 回のバス読み込みと命令デコードを完全にスキップして負荷を下げる。`settings.disasmEnabled` に永続化 |
| CPU Picker | 表示対象 CPU 切り替え (Main / Sub) |
| 📌 トグル | **PC 追従 ON/OFF**。ONで PC にロックオン (ピン留め) して追従、OFF で現在位置に固定してユーザーが自由にスクロール可能 |
| PC 表示 | 現在の PC (右端) |

- PC 追従 ON にすると `ScrollViewReader` 経由で現在 PC の行が自動的に画面中央にスクロールする
- Trace からのジャンプで OFF に切り替わるが、📌 トグルで ON に戻せる

### 4.2 Register ペイン

- メイン CPU / サブ CPU 両方のレジスタを同時表示
- AF / AF' / BC / BC' / DE / DE' / HL / HL' / IX / IY / SP / PC
- I, R, IFF1, IFF2, IM, HALTED フラグ

### 4.3 Breakpoint ペイン

6種類のブレークポイントを追加・削除・一括削除できる。

#### ヘッダのコントロール

| コントロール | 動作 |
|------------|------|
| Kind Picker | 追加するブレークポイントの種類 (Main PC / Sub PC / Mem R/W / IO R/W) |
| addr (hex) | アドレス入力。Mem W / IO W 選択時はバイト一致フィルタ (`==`) も入力可能 |
| Add | 入力内容で BP を追加 |
| ➡ トグル | **すべての BP を一括有効/無効**。ON (アクセント背景) = 全 BP 有効。OFF = 少なくとも1つ無効。BP 削除はしない |
| 🗑 | すべての BP を削除 |

#### ブレークポイントの種類

| 種類 | 説明 | 値フィルタ |
|------|------|-----------|
| **Main PC** | メイン CPU の PC が指定アドレスに達したら停止 | なし |
| **Sub PC** | サブ CPU の PC が指定アドレスに達したら停止 | なし |
| **Mem R** | 指定アドレスへのメモリ読み込み時に停止 | なし |
| **Mem W** | 指定アドレスへのメモリ書き込み時に停止 | 任意。指定バイトの書き込みのみ反応 |
| **IO R** | 指定 I/O ポートの読み込み時に停止 (下位8bit) | なし |
| **IO W** | 指定 I/O ポートの書き込み時に停止 (下位8bit) | 任意。指定バイトの書き込みのみ反応 |

- アドレス入力は `1234` / `0x1234` / `1234H` 形式をすべて受け付ける
- ブレークポイントヒット時は `Debugger.RunState.paused(reason: .breakpoint(id))` に遷移し、UI は自動的にスナップショットを更新する
- ヒットしたブレークポイント行はハイライト表示される

---

## 5. 下段タブ

### 5.1 Memory タブ

- 16 バイト×N 行のヘックスダンプ (ASCII プレビュー付き)
- アドレス入力フィールドでジャンプ、行数は 4〜64 行で Stepper 調整
- スナップショット経由でメイン Z80 バスのデータを表示

**永続化キー**: `debug.session.hexBaseAddress`, `debug.session.hexRowCount`

---

### 5.2 Trace タブ

メイン / サブ CPU の命令実行履歴をリングバッファで保持する。

#### リングバッファ仕様

- 容量: 各 CPU **1024 エントリ**
- 取得タイミング: 各 `cpu.step()` の直前 (命令実行前の状態を記録)
- 表示順: 最新を先頭にして降順表示

#### テーブル列

`#` / `PC` / `AF` / `BC` / `DE` / `HL` / `IX` / `IY` / `SP` / `Δ`

- **前のエントリからレジスタ値が変化したセル**はオレンジ+ボールドでハイライト
- **Δ列**: 変化したレジスタの `旧値→新値` サマリ (例: `HL:1A3B→1A3C  AF:0041→0040`)
- **行クリック**: 対応する PC へ Disassembly ペインがジャンプ

#### ヘッダのコントロール

| コントロール | 動作 |
|------------|------|
| CPU Picker (Main/Sub) | 表示する CPU を切り替え |
| Auto トグル | ポーズ時に自動更新 |
| ↺ Refresh | スナップショットを今すぐ取得 |
| ↑ Export | JSONL ファイルとして書き出し |
| 🗑 Clear | バッファをクリア |

#### JSONL エクスポート形式

```jsonl
{"pc":"1C5A","af":"0041","bc":"0000","de":"0000","hl":"1A3C","ix":"0000","iy":"0000","sp":"F800","af2":"0000","bc2":"0000","de2":"0000","hl2":"0000","i":"00","r":"42"}
```

**永続化キー**: `debug.trace.whichCPU`, `debug.trace.autoFollow`

---

### 5.3 PIO タブ

8255 PIO の全ポートアクセスをイベントストリームとして記録する。メイン CPU とサブ CPU のクロス通信デバッグに使う (RIGLAS 自己復号ハング、Wizardry ブートなど)。

#### リングバッファ仕様

- 容量: **4096 エントリ** (命令トレースより多い — ディスク転送1セクタで数百 PIO イベントが発生するため)
- 記録対象: Port A / Port B / Port C および **コントロールレジスタ書き込み** (ポート 0xFF — モード設定と BSR)

#### テーブル列

`#` / `Side` / `Port` / `Op` / `Val` / `Main PC` / `Sub PC`

- **Side**: Main (白) / Sub (オレンジ)
- **Port**: A / B / C / FF (コントロールレジスタ)
- **Op**: W (赤) / R (青)

#### フィルタ

- **Side フィルタ**: All / Main / Sub
- **Port フィルタ**: All / A / B / C

#### ヘッダのコントロール

| コントロール | 動作 |
|------------|------|
| Auto トグル | ポーズ時に自動更新 |
| ↺ Refresh | スナップショットを今すぐ取得 |
| ↑ Export | JSONL ファイルとして書き出し (スナップショット全件) |
| ⏺ Stream | ファイルへのリアルタイムストリーミングを開始/停止 |
| 🗑 Clear | バッファをクリア |

#### ファイルストリーミング

⏺ ボタンを押すと NSSavePanel で書き出し先を選択し、以降の全 PIO イベントをリングバッファの上限なしで JSONL に追記する。長時間の調査 (ゲーム起動全体など) に使う。ストリームは 64 KB 単位でフラッシュされる。

#### JSONL エクスポート形式

```jsonl
{"seq":42,"mainPC":"1C5A","subPC":"6830","side":"sub","port":"B","op":"W","val":"3B"}
```

同フォーマットは BubiC / QUASI88 側でも出力可能なので `diff` による直接比較ができる。

**永続化キー**: `debug.pio.sideFilter`, `debug.pio.portFilter`, `debug.pio.autoFollow`

---

### 5.4 GVRAM タブ

3 ビットプレーンの GVRAM を可視化する。

#### 表示モード

| モード | 200 ライン時 | 400 ライン時 |
|--------|------------|------------|
| **Composite** | 8 色 GRB デジタル合成 | Blue プレーン (上半面) + Red プレーン (下半面) を縦並びで Mono 表示 |
| **Blue** | Blue プレーンのみ Mono | Blue プレーンのみ (上半面相当) |
| **Red** | Red プレーンのみ Mono | Red プレーンのみ (下半面相当) |
| **Green** | Green プレーンのみ Mono | — (非表示) |

カラーモード時は `ScreenRenderer.expandPalette()` で展開したハードウェアパレットを使用。

#### ズーム

×1 / ×2 / ×4。ScrollView でスクロール可能。

#### ヘッダのコントロール

| コントロール | 動作 |
|------------|------|
| Mode Picker | 表示モード切り替え |
| Zoom Picker | ズームレベル切り替え |
| Auto トグル | 実行中 2 Hz 自動更新。ポーズ時は自動キャプチャ |
| ↺ Refresh | 今すぐキャプチャ |
| ↑ Export | バイナリ PPM (P6 形式) として書き出し |

#### ピクセル変換アルゴリズム

```
pixel (x, y):
  byteIdx = y * 80 + (x >> 3)
  bit     = 7 - (x & 7)
  B = (blue[byteIdx] >> bit) & 1
  R = (red[byteIdx]  >> bit) & 1
  G = (green[byteIdx]>> bit) & 1
  → palette[(G<<2)|(R<<1)|B]  // カラーモード
  → B ? 0xFF : 0x00           // Mono モード
```

**永続化キー**: `debug.gvram.displayMode`, `debug.gvram.zoom`, `debug.gvram.autoFollow`

---

### 5.5 Text タブ

テキスト VRAM を `ScreenRenderer.renderTextOverlay()` 経由で合成・表示する。

#### 表示内容

- 80 列 × 25 行 (または 40 列 × 20 行 — CRTC 設定に応じて可変)
- 解像度: 640×200 (通常) / 640×400 (400 ライン時)
- **CRTC カーソル位置**をオレンジ反転ブロックで強調表示

#### 属性デコードパネル

Attr ボタンで表示されるテーブル。全文字セルを一覧表示する。

| 列 | 内容 |
|----|------|
| Row / Col | セル位置 (0 始まり) |
| Code | 文字コード (16進) と ASCII プレビュー |
| Attr | 属性バイト生値 (16進) |
| GRB | カラーインデックス (bits 7-5) |
| Rev | リバースビデオ (bit 0) |
| Sec | シークレット/非表示 (bit 1) |
| Uln | アンダーライン (bit 3) |
| Grph | グラフ文字セット (bit 4) |

#### ヘッダのコントロール

| コントロール | 動作 |
|------------|------|
| Zoom Picker | ×1 / ×2 / ×4 |
| Attr トグル | 属性デコードパネルの表示/非表示 |
| Auto トグル | 実行中 2 Hz 自動更新。ポーズ時は自動キャプチャ |
| ↺ Refresh | 今すぐキャプチャ |
| ↑ Export | バイナリ PPM (P6 形式) として書き出し |

**永続化キー**: `debug.textvram.zoom`, `debug.textvram.autoFollow`, `debug.textvram.showAttrDecode`

---

### 5.6 Audio タブ

YM2608 の各チャンネルのアクティビティ表示・ミュート操作、スペアナを提供する。

#### チャンネルアクティビティ / ミュート

| グループ | チャンネル | アクティビティ判定 |
|---------|----------|-----------------|
| FM | ch 1〜6 | `fmKeyOnMask` の各ビット |
| SSG | A / B / C | `ssgMixer` の tone/noise enable かつ `ssgVolume > 0` |
| Rhythm | BD / SD / TOP / HH / TOM / RIM | `rhythmKey` の各ビット |
| ADPCM | ADC (1 ch) | `adpcmPlaying` |

- インジケータをクリックするとチャンネルをミュート/アンミュート
- **All On / All Off** ボタンで一括操作
- ミュート状態は**セッションスコープのみ** (UserDefaults 非永続)。デバッグウィンドウを閉じると全チャンネルがリセットされる

ミュートの仕組み: `YM2608.DebugChannelMask` を `EmulatorViewModel.applyDebugChannelMask(_:)` 経由で `emuQueue` に渡す。

#### スペアナ

- `AVAudioEngine.mainMixerNode` に tap を設置し、1024 サンプルブロックを `vDSP_fft_zrip` で FFT 処理
- 32 bin / 対数周波数軸 / dB 表示 (-60 dB〜0 dB)
- **Audio タブが表示されている間のみ** tap を設置。非表示時はゼロコスト

---

## 6. DebugSettings — 永続化キー一覧

`DebugSettings` クラスがすべての UI 設定を `UserDefaults.standard` に保存する。

| キー | 型 | デフォルト | 担当ペイン |
|-----|-----|---------|----------|
| `debug.session.focusedCPU` | String | `"Main"` | Disasm / Register |
| `debug.session.newBPKind` | String | `"Main PC"` | Breakpoint |
| `debug.session.hexBaseAddress` | Int | `0x0000` | Memory |
| `debug.session.hexRowCount` | Int | `16` | Memory |
| `debug.trace.whichCPU` | String | `"Main"` | Trace |
| `debug.trace.autoFollow` | Bool | `true` | Trace |
| `debug.pio.sideFilter` | String | `"All"` | PIO |
| `debug.pio.portFilter` | String | `"All"` | PIO |
| `debug.pio.autoFollow` | Bool | `true` | PIO |
| `debug.gvram.displayMode` | String | `"Composite"` | GVRAM |
| `debug.gvram.zoom` | Int | `1` | GVRAM |
| `debug.gvram.autoFollow` | Bool | `true` | GVRAM |
| `debug.textvram.zoom` | Int | `1` | Text VRAM |
| `debug.textvram.autoFollow` | Bool | `true` | Text VRAM |
| `debug.textvram.showAttrDecode` | Bool | `false` | Text VRAM |
| `debug.disasm.enabled` | Bool | `true` | Disassembly |

> **注意**: オーディオミュート状態 (`YM2608.DebugChannelMask`) は**永続化しない**。デバッグウィンドウを閉じるとすべてのチャンネルがアンミュートに戻る。

---

## 7. クロスエミュレータ比較ワークフロー

`diff` を使った行単位の比較が可能。

```bash
# 1. Bubilator88 でストリーミング開始 → game.d88 を起動 → 停止
#    → bubilator88-pioflow-stream.jsonl に保存

# 2. BubiC でも同フォーマットの JSONL を出力

# 3. diff
diff bubilator88-pioflow-stream.jsonl bubic-pioflow-stream.jsonl | head -40

# 4. 命令トレースも同様
diff bubilator88-trace-main.jsonl bubic-trace-main.jsonl
```

差分が最初に現れる行の `seq` 値が、クロス CPU 動作が diverge したポイント。そのエントリの `mainPC` / `subPC` をブレークポイントに設定して再現する。
