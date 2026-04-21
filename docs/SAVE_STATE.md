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
| 0x04 | 2 | UInt16 | フォーマットバージョン (現在: 2) |
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
| `META` | 0x4154454D | Yes | メタデータ JSON | ~100B |
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

#### Z80 CPU (メイン/サブ共通, 各約26バイト)

| プロパティ | 型 |
|-----------|-----|
| af, bc, de, hl | UInt16 × 4 |
| af2, bc2, de2, hl2 | UInt16 × 4 (裏レジスタ) |
| ix, iy, sp, pc | UInt16 × 4 |
| i, r | UInt8 × 2 |
| iff1, iff2 | Bool × 2 |
| im | UInt8 |
| halted, eiPending | Bool × 2 |

#### Pc88Bus (~150KB)

**メモリ (固定サイズ):**
- mainRAM: 64KB
- gvram[0-2]: 3 × 16KB = 48KB
- tvram: 4KB

**バンク切替状態:**
- romModeN88, ramMode, gamMode, evramMode (Bool × 4)
- gvramPlane (Int)
- extROMBank, n88ExtROMSelect, textWindowOffset (UInt8 × 3)
- extROMEnabled (Bool)

**表示制御:**
- port30w, borderColor, layerControl (UInt8 × 3)
- colorMode, columns80, analogPalette (Bool × 3)
- graphicsDisplayEnabled, graphicsColorMode, mode200Line (Bool × 3)

**拡張RAM (可変長):**
- カード数 (UInt32) → 0 なら拡張RAM なし
- 各カード: バンク数 (UInt32) → 各バンク 32KB
- extRAMWriteEnable, extRAMReadEnable (Bool × 2)
- extRAMCard, extRAMBank (Int × 2)

**その他:**
- kanjiAddr1, kanjiAddr2 (UInt16 × 2)
- aluControl1, aluControl2, aluReg[0-2] (UInt8 × 5)
- port31, port32, port40w (UInt8 × 3)
- cpuClock8MHz, vrtcFlag, directBasicBoot, tvramEnabled (Bool × 4)
- pendingWaitStates (Int)
- palette[0-7]: 各 (b, r, g) = UInt8 × 3 × 8 = 24バイト

#### InterruptController (7バイト)

| プロパティ | 型 |
|-----------|-----|
| pendingLevels, levelThreshold | UInt8 × 2 |
| sgsMode, maskRTC, maskVRTC, maskRXRDY, maskSound | Bool × 5 |

#### DMAController (30バイト)

チャネル × 4:
- address, count (UInt16 × 2)
- mode (UInt8), enabled (Bool)

グローバル:
- modeRegister (UInt8), flipFlop (Bool)

#### Keyboard (15バイト)

- matrix[0-14]: UInt8 × 15

#### CRTC (~24KB)

固定プロパティ (scanline, displayEnabled, mode200Line, 表示パラメータ, blinkRate/blinkCounter/blinkAttribBit, カーソル, vretrace 等) + parameters 配列 (長さプレフィックス付き) + dmaBuffer (24,000バイト固定)

> フォーマット v2 (2026-04) で `blinkCounter` (Int) と `blinkAttribBit` (UInt8) が
> `blinkRate` と `vretrace` の間に追加された。v1 ファイルはロード時に拒否される。

#### YM2608 (~260KB, 長さプレフィックス付き)

長さプレフィックス (UInt32) + 以下を連結:

- レジスタバンク: registers[256] + extRegisters[256] + selectedAddr × 2 = 514バイト
- タイマ状態 (A/B カウンタ, 有効/オーバーフロー/IRQ フラグ)
- FM状態 (fmSampleCounter, fNum[6], fNum3[3])
- SSG状態 (トーン/ノイズ/エンベロープ/バンドリミット)
- ADPCM状態 (アドレス, プレイバック, 出力, adpcmReadBuffer)
- ADPCM RAM: 256KB固定
- ビープ状態 (beepOn, singSignal, beepPhase)
- FMSynthesizer ブロブ (長さプレフィックス付き, ~8KB)

##### FMSynthesizer (~8KB)

- FMチャネル × 6: 各チャネルに FMOp × 4 (全オペレータパラメータ)
- LFO状態
- リズムチャネル × 6 (pos, step, pan, level, volume)
- リズム制御 (TL, key, extendedChannelsEnabled)

#### SubSystem (~100KB+)

- サブCPU (Z80, 26バイト)
- SubBus: romram 32KB + motorOn[4] + driveSelect + currentSubPC
- PIO8255: ポート状態 (2 sides × 3 ports) + portAB/portC + pendingAB
- UPD765A FDC (長さプレフィックス付き, ~1-2KB): phase, command, バッファ, CHRN, ステータス, シーク状態, タイミング
- CPUスケジューリング状態 (subCpuTStates, pioInterleave等)
- レガシーモード状態 (useLegacyMode 時のコマンドプロセッサ全体)

#### UPD1990A (11バイト)

- shiftReg[0-6] (UInt8 × 7)
- cdo (Bool), command (UInt8), din (Bool), prevCtrl (UInt8)

#### Machine メタデータ

- totalTStates (UInt64)
- rtcCounter (Int)
- subCpuAccumulator (Int)
- clock8MHz (Bool)
- traceEnabled (Bool)

---

### DSK0 / DSK1 セクション

`D88Disk.serialize()` で生成した D88 バイナリデータをそのまま格納。

- セクションが存在する → `D88Disk.parse(data:)` で復元してマウント
- セクションが存在しない → ドライブをイジェクト

### META セクション

JSON 形式のメタデータ:

```json
{
  "disk0": "ディスク名",
  "disk1": null,
  "clock8MHz": true,
  "drive0SourceURL": "file://~/Disks/Ys.d88",
  "drive1SourceURL": null,
  "drive0ImageIndex": 0,
  "drive1ImageIndex": null,
  "drive0ArchiveEntry": null,
  "drive1ArchiveEntry": null
}
```

ロード時、MAIN と DSK セクションがエミュレータ状態を復元する。META の `drive*SourceURL` は元ファイルの絶対パスで、ロード後にディスク切替メニューを再構成するために使われる (元ファイルが存在すればマルチイメージの全ディスクが利用可能になる)。

`drive*ArchiveEntry` は ZIP/LHA 等のアーカイブからディスクをマウントした場合に、アーカイブ内のエントリファイル名を保持する。この場合 `drive*SourceURL` はアーカイブファイル自体のパスを指す。ロード時にアーカイブを再展開して該当エントリの D88 を再パースすることで、マルチイメージ切替を復元する。`drive*ArchiveEntry` が null の場合、`drive*SourceURL` は D88 ファイルへの直接パス (従来動作) か、Mount 0&1 モードでアーカイブ全エントリを展開する。

### THMB セクション

サムネイル画像データ。アプリ層で付加される (EmulatorCore は関与しない)。

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
}
```

### Machine API

```swift
extension Machine {
    func createSaveState(thumbnail: [UInt8]?) -> [UInt8]
    mutating func loadSaveState(_ data: [UInt8]) throws
}
```

エラー型: `SaveStateError` — endOfData, invalidMagic, unsupportedVersion, missingSections, sectionTooSmall, invalidData

---

## 5. バージョン互換性

- **前方互換**: 未知のセクションタグはスキップ → 新セクション追加は安全
- **後方互換**: `version < 2` または `version > currentVersion` → ロード拒否 (`unsupportedVersion` エラー)
- **セクション内拡張**: 末尾追加方式。Reader の remaining > 0 なら追加データを読める
- 破壊的変更時のみバージョン番号をインクリメント

### 変更履歴

| Version | 日付 | 内容 |
|---------|------|------|
| 1 | — | 初版 (pre-release) |
| 2 | 2026-04 | CRTC に `blinkCounter` / `blinkAttribBit` 追加 (BLINK 属性実装) + YM2608 に `adpcmReadBuffer` 追加 (ADPCM RAM memory-read ラッチ復元)。v1 は拒否 |

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
| アーカイブ由来のディスク | META に archiveEntry を記録。ロード時にアーカイブを再展開 |
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
- 各スロットに付随: `.meta.json` (ブートモード, ディスク名), `.thumb.png` (320×200 サムネイル)
- メニューから選択

### ファイル構成

→ 詳細は PERSISTENCE.md 参照
