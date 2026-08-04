# ステートセーブ フォーマット仕様

エミュレータの任意時点の全ハードウェア状態を保存・復元する。
ディスクイメージを含む完全なスナップショット。

---

## 1. ファイルフォーマット

**方式**: セクションベースのフラットバイナリ  
**拡張子**: `.b88s`  
**バイトオーダー**: 全てリトルエンディアン  
**圧縮**: なし  
**チェックサム**: なし (ファイルシステムに依存)

### ヘッダ (64バイト固定)

| Offset | Size | 型 | 内容 |
|--------|------|----|------|
| 0x00 | 4 | UInt32 | マジック `0x38385542` (ASCII "BU88") |
| 0x04 | 2 | UInt16 | フォーマットバージョン (現在: 3) |
| 0x06 | 2 | UInt16 | 予約 |
| 0x08 | 8 | Double | タイムスタンプ (Unix epoch) |
| 0x10 | 32 | UTF-8 | エミュレータバージョン文字列 (null-padded) |
| 0x30 | 4 | UInt32 | フラグ (現在: 未使用, 0) |
| 0x34 | 4 | UInt32 | サムネイルオフセット |
| 0x38 | 4 | UInt32 | サムネイルサイズ |
| 0x3C | 4 | UInt32 | セクション数 |

### セクションテーブル (N × 12バイト)

ヘッダ直後に続く。各エントリ:

| Offset | Size | 型 | 内容 |
|--------|------|----|------|
| +0 | 4 | UInt32 | FourCC タグ |
| +4 | 4 | UInt32 | データオフセット (ファイル先頭から) |
| +8 | 4 | UInt32 | データサイズ |

### セクション一覧

| Tag | FourCC | 必須 | 内容 | サイズ目安 |
|-----|--------|------|------|-----------|
| `MAIN` | 0x4E49414D | Yes | 全コンポーネント状態 (シリアライズ連結) | ~500KB |
| `DSK0` | 0x304B5344 | No | ドライブ0 D88イメージ | 0-1.2MB |
| `DSK1` | 0x314B5344 | No | ドライブ1 D88イメージ | 0-1.2MB |
| `CMT ` | 0x20544D43 | No | カセットデッキ + I8251 (テープマウント時のみ) | テープサイズ依存 |
| `META` | 0x4154454D | Yes | メタデータ JSON | ~100B |
| `AMTA` | 0x41544D41 | No | アプリ層メタデータ JSON (アプリが書く) | ~300B |
| `THMB` | 0x424D4854 | No | サムネイル画像 | ~10KB |

**推定ファイルサイズ**: ディスクなし ~500KB、2HD×2 ~2.9MB

---

## 2. セクション詳細

### MAIN セクション

全コンポーネントの状態が以下の順序で連結される。個別セクションには分割されない。

**シリアライズ順序:**

1. Z80 メインCPU
2. Pc88Bus (RAM, GVRAM, TVRAM, バンク切替, 表示制御, 拡張RAM, パレット, ALU)
3. InterruptController
4. Keyboard
5. DMAController
6. CRTC
7. YM2608 (長さプレフィックス付きブロブ)
8. SubSystem (サブCPU, SubBus, PIO, FDC, スケジューリング状態)
9. UPD1990A (カレンダ)
10. Machine メタデータ (totalTStates, rtcCounter, clock8MHz 等)

#### Z80 CPU (メイン/サブ共通, 各31バイト)

書き込み順。Bool は 1 バイト、Int は Int64 として 8 バイト。

| プロパティ | 型 |
|-----------|-----|
| af, bc, de, hl | UInt16 × 4 |
| af2, bc2, de2, hl2 | UInt16 × 4 (裏レジスタ) |
| ix, iy, sp, pc | UInt16 × 4 |
| i, r | UInt8 × 2 |
| iff1, iff2 | Bool × 2 |
| im | UInt8 |
| halted, eiPending | Bool × 2 |

#### Pc88Bus

固定メモリだけで 116KB (mainRAM 64KB + GVRAM 48KB + tvram 4KB)。拡張RAM を
積んでいるとカード枚数 × バンク数 × 32KB が加算される。

**メモリ (固定サイズ):**
- mainRAM: 64KB
- gvram[0-2]: 3 × 16KB = 48KB
- tvram: 4KB

**バンク切替状態 (この順):**
- romModeN88, ramMode (Bool × 2)
- gvramPlane (Int)
- gamMode, evramMode (Bool × 2)
- extROMBank, n88ExtROMSelect (UInt8 × 2)
- extROMEnabled (Bool)
- textWindowOffset (UInt8)

**表示制御:**
- port30w, borderColor, layerControl (UInt8 × 3)
- colorMode, columns80, analogPalette (Bool × 3)
- graphicsDisplayEnabled, graphicsColorMode, mode200Line (Bool × 3)

**拡張RAM (可変長):**
- カード数 (UInt32) → 0 なら拡張RAM なし
- 各カード: バンク数 (UInt32) → 各バンク 32KB
- extRAMWriteEnable, extRAMReadEnable (Bool × 2)
- extRAMCard, extRAMBank (Int × 2)

**その他 (この順):**
- kanjiAddr1, kanjiAddr2 (UInt16 × 2)
- aluControl1, aluControl2, aluReg[0-2] (UInt8 × 5)
- port31, port32, port40w (UInt8 × 3)
- cpuClock8MHz, vrtcFlag, directBasicBoot (Bool × 3)
- pendingWaitStates (Int)
- tvramEnabled (Bool)
- palette[0-7]: 各 (b, r, g) = UInt8 × 3 × 8 = 24バイト

#### InterruptController (7バイト)

| プロパティ | 型 |
|-----------|-----|
| pendingLevels, levelThreshold | UInt8 × 2 |
| sgsMode, maskRTC, maskVRTC, maskRXRDY, maskSound | Bool × 5 |

#### DMAController (26バイト)

チャネル × 4:
- address, count (UInt16 × 2)
- mode (UInt8), enabled (Bool)

グローバル:
- modeRegister (UInt8), flipFlop (Bool)

#### Keyboard (15バイト)

- matrix[0-14]: UInt8 × 15

#### CRTC (~24KB)

書き込み順:

1. scanline (Int), vrtcFlag (Bool), tStateAccumulator (Int), displayEnabled,
   mode200Line (Bool × 2)
2. parameters 配列 (UInt32 長さ + データ), parameterIndex, expectedParameters (Int × 2),
   currentCommand (UInt8)
3. 表示パラメータ — charsPerLine, linesPerScreen, charLinesPerRow (UInt8 × 3),
   skipLine (Bool), displayMode (UInt8), attrNonTransparent (Bool),
   attrsPerLine, intrMask (UInt8 × 2), reverseDisplay (Bool)
4. カーソル — cursorX, cursorY (Int × 2), cursorEnabled (Bool), cursorMode (UInt8)
5. blinkRate, blinkCounter (Int × 2), blinkAttribBit (UInt8), vretrace (Int)
6. dataReady, lightPen, underrun (Bool × 3)
7. dmaBuffer (24,000バイト固定), dmaBufferPtr (Int), dmaUnderrun (Bool)

> フォーマット v2 (2026-04) で `blinkCounter` (Int) と `blinkAttribBit` (UInt8) が
> `blinkRate` と `vretrace` の間に追加された。v1 ファイルはロード時に拒否される。

#### YM2608 (~260KB, 長さプレフィックス付き)

長さプレフィックス (UInt32) + 以下を連結:

- レジスタバンク: registers[256] + extRegisters[256] + selectedAddr / selectedExtAddr
  = 514バイト
- タイマ状態 (A/B カウンタ, 有効/オーバーフロー/IRQ フラグ, statusMask, irqControl,
  irqAsserted, busyStatusCounter)
- clock8MHz
- FM状態 (fmSampleCounter, fmFNumMain[6], fmFNum3[3])
- SSG状態 (トーン/ノイズ/エンベロープ) + バンドリミット状態 (位相/ステップ/出力レベル)
- ADPCM状態 (アドレス, プレイバック, 出力, adpcmReadBuffer)
- ADPCM RAM: 256KB固定
- ミキサ出力ラッチ (audioSampleAccum, fmOutputL/R, rhythmOutputL/R)
- ビープ状態 (beepOn, singSignal, beepPhase)
- FMSynthesizer ブロブ (長さプレフィックス付き, ~8KB)

##### FMSynthesizer (~8KB)

書き込み順:

- FMチャネル × 6: 各チャネルに FMOp × 4 (全オペレータパラメータ) +
  fb / algo / panLeft / panRight / pmsIndex
- ratio (UInt32) + multable[4][16] (UInt32 × 64)
- LFO状態 (lfoCount, lfoDCount, lfoEnabled)
- リズムチャネル × 6 (size, pos, step, pan, level, volumeL, volumeR)
- リズム制御 (rhythmTL, rhythmVolL/R, rhythmKey, extendedChannelsEnabled)
- chipClock, outputRate (Int × 2)

#### SubSystem (~100KB+)

書き込み順:

- サブCPU (Z80, 31バイト)
- SubBus: romram 32KB + motorOn[4] + driveSelect + currentSubPC
- PIO8255: ポート状態 (2 sides × 3 ports) + portAB/portC + pendingAB +
  clearPortsByCommandRegister
- UPD765A FDC (長さプレフィックス付き, ~1-2KB): phase, command, バッファ, CHRN,
  ステータス, per-drive シーク状態, SPECIFY タイミング, フォーマット ID, 実行コンテキスト
- diskAccess[0-1] (アクセスランプ), subCpuTStates
- レガシーモード状態 (useLegacyMode 時のコマンドプロセッサ全体)
- デバッグカウンタ (commandCount, lastCommand, fdcInterruptDeliveredCount)

> v3 でサブCPU 追い上げヒューリスティックのフィールド
> (`pioInterleaveInstructionsRemaining` 等) は削除された。ここには残っていない。

#### UPD1990A (11バイト)

- shiftReg[0-6] (UInt8 × 7)
- cdo (Bool), command (UInt8), din (Bool), prevCtrl (UInt8)

#### Machine メタデータ

- totalTStates (UInt64)
- rtcCounter (Int)
- subAccumClocks (Int)
- subDebt (Int)
- clock8MHz (Bool)
- traceEnabled (Bool)

> `subAccumClocks` / `subDebt` は v3 のスケジューラ移行で v2 の
> `subCpuAccumulator` を置き換えたもの。

---

### DSK0 / DSK1 セクション

`D88Disk.serialize()` で生成した D88 バイナリデータをそのまま格納。

- セクションが存在する → `D88Disk.parse(data:)` で復元してマウント
- セクションが存在しない → ドライブをイジェクト

### `CMT ` セクション

テープをマウントしている状態 (`cassette.isLoaded`) でのみ書かれる。I8251 と
CassetteDeck の 2 ブロブを長さプレフィックス付きで並べたもの:

```
[usartLen(u32 LE)][I8251 state][deckLen(u32 LE)][CassetteDeck state]
```

セクションが無いロードは eject 相当 — `cassette.eject()` + `usart.reset()` が走る。
テープバッファ本体を含むので、大きなテープでは `.b88s` もその分肥大する
(内訳は PERSISTENCE.md)。

### META セクション

JSON 形式のメタデータ:

EmulatorCore が文字列連結で組み立てる 3 フィールドのみ。ディスク未挿入なら名前は
空文字列になる。

```json
{"disk0":"ディスク名","disk1":"","clock8MHz":true}
```

エミュレータ状態の復元は MAIN と DSK セクションが担う。META はそれ自体では復元に
使われず、ファイルを開かずに中身を知りたい側 (Quick Look プレビュー拡張) の
情報源になっている。

ディスクの再マウント情報 — `drive*SourceURL` (元ファイルの絶対パス)、
`drive*ImageIndex`、`drive*ArchiveEntry` — は META ではなく **`AMTA`** にある。
ロード後にディスク切替メニューを再構成するのはアプリ層の仕事で、元ファイルが
存在すればマルチイメージの全ディスクが再び利用可能になる。

`drive*ArchiveEntry` は ZIP/LHA 等のアーカイブからディスクをマウントした場合に、アーカイブ内のエントリファイル名を保持する。この場合 `drive*SourceURL` はアーカイブファイル自体のパスを指す。ロード時にアーカイブを再展開して該当エントリの D88 を再パースすることで、マルチイメージ切替を復元する。`drive*ArchiveEntry` が null の場合、`drive*SourceURL` は D88 ファイルへの直接パス (従来動作) か、Mount 0&1 モードでアーカイブ全エントリを展開する。

### AMTA セクション

アプリ層のメタデータ (`EmulatorViewModel.SaveMeta` を `JSONEncoder` で符号化した
もの)。ブートモード、ドライブ名/ファイル名、`drive*SourceURL`、`drive*ImageIndex`、
`drive*ArchiveEntry` を含み、`META` より情報量が多い。

EmulatorCore はこのタグの意味を知らない。アプリ層が
`createSaveState(extraSections:)` で渡し、`SaveStateFileAccess.readSection` で
読み出す。旧ビルドは同内容を `.meta.json` サイドカーに書いていた。現行は書かないが、
旧スロット向けに読みフォールバックだけ残してある (→ PERSISTENCE.md)。

### THMB セクション

サムネイル画像データ (320×200 PNG)。アプリ層が `createSaveState(thumbnail:)` に
渡す (EmulatorCore は中身に関与しない)。ヘッダ 0x34/0x38 にオフセットとサイズが
書かれるほか、セクションテーブルにも `THMB` として載る。

---

## 3. 保存対象の判断

### 保存する

- 全CPU状態 (メイン/サブ Z80 レジスタ, フラグ, IM, halt, eiPending)
- 全メモリ (mainRAM 64KB, GVRAM 48KB, tvram 4KB, 拡張RAM, SubBus romram 32KB, ADPCM RAM 256KB)
- 全I/Oポート状態, バンク切替状態, ALU状態
- タイミングカウンタ (totalTStates, scanline, タイマカウンタ等)
- FMSynthesizer 全状態 (6ch × 4op, LFO, リズム pos/step)
- FDC 全状態 (phase, command, seek 状態, ステータス, 実行コンテキスト)
- PIO 全状態 (クロスワイヤポート, ハンドシェイク)
- サブCPUスケジューリング状態
- ディスクイメージ (D88 シリアライズデータ丸ごと)

### 保存しない

- **ROM データ**: 静的。ファイルから再ロード
- **リズム WAV サンプル**: 固定データ。再ロード
- **audioBuffer**: 一時的。クリア
- **トレース/デバッグ状態**: 不要 (traceEnabled のみ保存)
- **コールバック/クロージャ**: ロード後に再接続
- **算出プロパティ/静的テーブル**: 再計算

---

## 4. シリアライズ API

### SaveStateWriter / SaveStateReader

```swift
struct SaveStateWriter: Sendable {
    mutating func writeUInt8(_ v: UInt8)
    mutating func writeUInt16(_ v: UInt16)       // LE
    mutating func writeUInt32(_ v: UInt32)       // LE
    mutating func writeUInt64(_ v: UInt64)       // LE
    mutating func writeInt(_ v: Int)             // Int64 bitcast, LE
    mutating func writeBool(_ v: Bool)           // 1 or 0
    mutating func writeFloat(_ v: Float)         // UInt32 bitcast, LE
    mutating func writeDouble(_ v: Double)       // UInt64 bitcast, LE
    mutating func writeBytes(_ data: [UInt8])
    mutating func writeLengthPrefixedBytes(_ data: [UInt8])  // UInt32 長さ + データ
}

struct SaveStateReader: Sendable {
    func readUInt8() throws -> UInt8
    // ... (Writer と対称)
    func readLengthPrefixedBytes() throws -> [UInt8]
    func skip(_ count: Int) throws
}
```

### SaveStateFile

```swift
enum SaveStateFile {
    static func build(sections: [(tag: UInt32, data: [UInt8])],
                      thumbnail: [UInt8]?) -> [UInt8]
    static func parse(_ data: [UInt8]) throws -> [UInt32: [UInt8]]

    /// Header + section table only. Lets a caller seek to one section
    /// without reading the whole file. EmulatorCore does no file I/O —
    /// the caller reads the leading bytes and seeks itself.
    static func parseSectionTable(_ data: [UInt8]) throws
      -> [(tag: UInt32, offset: Int, size: Int)]
}
```

### Machine API

```swift
extension Machine {
    func createSaveState(thumbnail: [UInt8]? = nil,
                         extraSections: [(tag: UInt32, data: [UInt8])] = []) -> [UInt8]
    mutating func loadSaveState(_ data: [UInt8]) throws
}
```

エラー型: `SaveStateError` — endOfData, invalidMagic, unsupportedVersion, missingSections, sectionTooSmall, invalidData

---

## 5. バージョン互換性

- **前方互換**: 未知のセクションタグはスキップ → 新セクション追加は安全。
  `parse` は全タグを辞書に入れるだけ、`loadSaveState` は既知タグを辞書引きするだけで、
  セクション数の検証も未知タグの拒否も行わない。**アプリ層セクション (`AMTA` など) の
  追加でバージョンを上げる必要はない** — 古いビルドでも状態復元は成功し、そのセクションが
  無視されるだけ
- **後方互換**: `version < 3` または `version > currentVersion` → ロード拒否 (`unsupportedVersion` エラー)
- **セクション内拡張**: 末尾追加方式。Reader の remaining > 0 なら追加データを読める
- 破壊的変更時のみバージョン番号をインクリメント

### 変更履歴

| Version | 日付 | 内容 |
|---------|------|------|
| 1 | — | 初版 (pre-release) |
| 2 | 2026-04 | CRTC に `blinkCounter` / `blinkAttribBit` 追加 (BLINK 属性実装) + YM2608 に `adpcmReadBuffer` 追加 (ADPCM RAM memory-read ラッチ復元)。v1 は拒否 |
| 3 | 2026-04-21 | BubiC event.cpp スケジューラ移行に伴い chase-heuristic フィールド (`needsSubCPURun`, `pioInterleaveInstructionsRemaining`, `subPortBWriteGeneration`, `pendingFreshMainPort*`, `pendingATNIdleLoopObservation` 等) を削除。v2 は拒否 (出典: `SaveState.swift:179`) |

> §2 のレイアウト記述は 2026-08-04 に `writeSaveState` 系の実装と突き合わせ済み。

---

## 6. ディスク処理

### セーブ時

- `D88Disk.serialize()` で D88 バイナリ化 → `DSK0`/`DSK1` セクションに格納
- META にディスク名を記録 (参照用)

### ロード時

- `DSK0`/`DSK1` セクションから `D88Disk.parse(data:)` で復元してマウント
- セクションなし → ドライブをイジェクト (前の状態は残さない)

### エッジケース

| ケース | 動作 |
|--------|------|
| 元 D88 ファイル削除済み | セーブデータ内に D88 データ内包。問題なし |
| ディスク変更後にロード | セーブ時のディスクに巻き戻る (正常動作) |
| ダーティセクター | serialize() が全データを含む。完全復元 |
| 書込み禁止フラグ | D88 ヘッダに含まれる。復元される |
| アーカイブ由来のディスク | `AMTA` に archiveEntry を記録。ロード時にアーカイブを再展開 |
| 元アーカイブ削除済み | DSK セクション内の D88 データで復元。ディスク切替は不可 |

---

## 7. UI/UX (アプリ層)

### クイックセーブ・ロード

- **Cmd+S** = クイックセーブ (`quicksave.b88s`)
- **Cmd+L** = クイックロード
- 即座に実行、確認ダイアログなし

### セーブスロット (10個)

- スロット 0-9
- `~/Library/Application Support/Bubilator88/SaveStates/slot_N.b88s`
- ブートモード/ディスク名は `AMTA`、サムネイルは `THMB` として `.b88s` 内に入る
  (旧ビルドの `.meta.json` / `.thumb.png` サイドカーは読みのみ対応)
- メニューから選択

### ファイル構成

→ 詳細は PERSISTENCE.md 参照
