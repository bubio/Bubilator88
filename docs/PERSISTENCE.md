# Bubilator88 永続化データ一覧

アプリが保存・参照する全てのデータの所在と形式。

---

## 1. ユーザ設定 (UserDefaults)

`Settings.swift` で一元管理。`UserDefaults.standard` に保存される。

### CPU / システム

| キー | 型 | デフォルト | 説明 |
|------|-----|----------|------|
| `clock8MHz` | Bool | false | CPUクロック (true=8MHz, false=4MHz) |
| `dipSw1` | Int (UInt8) | 0xC3 | DIP SW1 (Port 0x30 Read) |
| `dipSw2Base` | Int (UInt8) | 0x71 | DIP SW2 (Port 0x31 Read, bit3除く) |

### 映像

| キー | 型 | デフォルト | 説明 |
|------|-----|----------|------|
| `videoFilter` | String | "None" | ビデオフィルタ (None/Linear/Bicubic/CRT/xBRZ/Enhanced/AI) |
| `scanlineEnabled` | Bool | false | スキャンラインオーバーレイ |
| `windowScale` | Int | 1 | ウィンドウ倍率 (1/2/4) |
| `fullscreenIntegerScaling` | Bool | false | フルスクリーン整数スケーリング |
| `screenshotFormat` | String | "png" | スクリーンショット形式 (png/jpeg/heic) |

### 音声

| キー | 型 | デフォルト | 説明 |
|------|-----|----------|------|
| `volume` | Float | 0.5 | マスターボリューム (0.0-1.0) |
| `pseudoStereo` | Bool | false | 擬似ステレオ (コーラスエフェクト) |
| `audioBufferMs` | Int | 100 | オーディオバッファサイズ (20-500ms) |
| `spatialAudio` | Bool | false | イマーシブオーディオ |
| `immersivePositions` | Data (JSON) | defaults | チャネル別3D配置 (FM/SSG/ADPCM/Rhythm) |
| `fddSound` | Bool | true | FDDアクセス音 |

### 入力 (キーボード)

| キー | 型 | デフォルト | 説明 |
|------|-----|----------|------|
| `keyboardLayout` | String | "auto" | キーボードレイアウト (auto/jis/us) |
| `arrowKeysAsNumpad` | Bool | false | 矢印キー→テンキーマッピング |
| `numberRowAsNumpad` | Bool | false | 数字行→テンキーマッピング |
| `specialKeyMapping` | Data (JSON) | {} | PC-8801特殊キーのカスタム割当 |

### 入力 (ゲームコントローラ)

| キー | 型 | デフォルト | 説明 |
|------|-----|----------|------|
| `gameControllerEnabled` | Bool | true | コントローラ入力有効 |
| `controllerHapticEnabled` | Bool | true | ディスクアクセス時の触覚フィードバック |
| `controllerMappings` | Data (JSON) | {} | コントローラ種別ごとのボタンマッピング |

### 入力 (マウス)

| キー | 型 | デフォルト | 説明 |
|------|-----|----------|------|
| `mouseEnabled` | Bool | false | マウス入力有効。ON 時はホストカーソルを捕捉 (非表示+ロック) し相対移動/左右ボタンを OPN ポート経由で供給 |
| `mouseJoyMode` | Bool | false | マウス読み取りモード。false=バスマウス (PC-8872 ストローブ式4段ニブル) / true=ジョイモード (マウス→ジョイスティック、OPNポートをジョイスティックとして読むゲーム用) |
| `mouseSensitivity` | Float | 1.0 | マウス移動感度倍率 (0.5x–3.0x) |

### その他

| キー | 型 | デフォルト | 説明 |
|------|-----|----------|------|
| `translationTargetLanguage` | String | "en-Latn-US" | 翻訳オーバーレイの対象言語 (BCP 47) |
| `showDebugMenu` | Bool | false | DEBUGメニュー表示 |
| `showTapeInStatusBar` | Bool | false | ステータスバーにテープアイコン表示 |
| `scriptRecordingAutoSave` | Bool | true | 操作スクリプト記録の自動保存 (false=毎回保存先確認) |
| `scriptRecordingDirectory` | String? | nil (~/Documents) | `.b88script` 記録の自動保存先 (絶対パス) |
| `recentDiskFiles` | Data (JSON) | [] | 最近使用したディスク (最大10件, セキュリティスコープ付きブックマーク) |
| `recentTapeFiles` | Data (JSON) | [] | 最近使用したテープ (最大10件, セキュリティスコープ付きブックマーク) |

---

## 2. ROM ファイル

**ディレクトリ:** `~/Library/Application Support/Bubilator88/`

アプリにはバンドルしない。ユーザが配置する。

| ファイル名 | サイズ | 必須 | 説明 |
|-----------|--------|------|------|
| `N88.ROM` | 32KB | Yes | N88-BASIC ROM |
| `N80.ROM` | 32KB | No | N-BASIC ROM |
| `DISK.ROM` | 8KB | No | サブCPU ROM (ディスクアクセスに必要) |
| `N88_0.ROM` ~ `N88_3.ROM` | 8KB×4 | No | N88 拡張ROM バンク0-3 |
| `FONT.ROM` | 2KB | No | フォントROM (なければ内蔵ASCII使用) |
| `KANJI1.ROM` | 128KB | No | 漢字ROM 第一水準 |
| `KANJI2.ROM` | 128KB | No | 漢字ROM 第二水準 |

### YM2608 リズム音源サンプル

同ディレクトリに配置。符号付き16bit PCM WAV。

| ファイル名 | 音色 |
|-----------|------|
| `2608_BD.WAV` | バスドラム |
| `2608_SD.WAV` | スネアドラム |
| `2608_TOP.WAV` | シンバル |
| `2608_HH.WAV` | ハイハット |
| `2608_TOM.WAV` | タム |
| `2608_RIM.WAV` | リムショット |

---

## 3. セーブステート

**ディレクトリ:** `~/Library/Application Support/Bubilator88/SaveStates/`

### ファイル構成 (スロットごと)

| ファイル | 形式 | 説明 |
|---------|------|------|
| `slot_N.b88s` | バイナリ | エミュレータ全状態 (→ SAVE_STATE.md) |
| `slot_N.meta.json` | JSON | ブートモード, ディスク名, クロック設定 |
| `slot_N.thumb.png` | PNG | サムネイル (320×200) |

- N = 0-9 (10スロット)
- クイックセーブ: `quicksave.b88s` / `.meta.json` / `.thumb.png`

### メタデータ (meta.json) の内容

```json
{
  "bootMode": "N88-BASIC V2",
  "clock8MHz": true,
  "disk0": "Ys",
  "disk1": null,
  "drive0Name": "Ys Disk A",
  "drive1Name": null,
  "drive0FileName": "Ys.d88",
  "drive1FileName": null,
  "drive0SourceURL": "~/Disks/Ys.d88",
  "drive1SourceURL": null,
  "drive0ImageIndex": 0,
  "drive1ImageIndex": null
}
```

### カセットテープ (`CMT ` セクション)

テープをマウントしている状態でセーブすると、`.b88s` 内に FourCC `CMT `
セクションが追加される。内容:

```
[usartLen(u32 LE)][I8251 state bytes]
[deckLen(u32 LE)][CassetteDeck state bytes]
```

- I8251 state: version / writeExpect / mode / command / status / rxBuf (6 バイト)
- CassetteDeck state v2: version(2) / motorOn / cmtSelected / phase /
  bytePeriodTStates / primeDelayTStates / bufPtr / tickAccum /
  buffer 全体 / dataCarriers 配列 (v1 からの読み込みも後方互換)

テープバッファ本体を含むため、大きなテープ (~1MB) では `.b88s` もその分
肥大する。テープ非マウントなら CMT セクション自体が書かれず、ロード側は
自動で eject 相当の状態になる。

### ショートカット

| 操作 | キー |
|------|------|
| クイックセーブ | Cmd+S |
| クイックロード | Cmd+L |
| スロット選択 | メニューから |

---

## 4. AI アップスケーリングモデル

3 モデル(Fast/Balanced/Quality)。macOS は CoreML(`.mlmodelc`)、Windows/Linux は
ONNX Runtime(`.onnx`)で **同一の重み**を実行する。両形式はリポジトリの単一 source-of-truth
`.pth`(`models/*.pth`, Git LFS)から生成される(`scripts/convert_srvggnet_onnx.py` /
`convert_realesrgan_onnx.py` / `train_srvggnet.py` の CoreML 出力)。詳細と再学習手順は
`models/PROVENANCE.md`。

**読み込み (macOS):** アプリバンドル (Resources/) のみ。AI モデルは常に同梱するため、
外部 override 参照は廃止した(以前あった `~/Library/Application Support/Bubilator88/Models/`
探索は、stale な override がバンドルを黙って上書きして Windows ONNX と食い違う原因になった
ため削除)。

**読み込み (Windows):** EXE と同じ出力ディレクトリのみ(csproj が `models/onnx/*.onnx` を
コピー)。macOS と同様、外部 override(`%LOCALAPPDATA%\Bubilator88\Models\`)参照は廃止。

| フィルタ | CoreML (macOS) | ONNX (Windows/Linux) | 素性 |
|----------|----------------|----------------------|------|
| Fast     | `SRVGGNet_x2_lite.mlmodelc` | `SRVGGNet_x2_lite.onnx` | 自前学習(蒸留)。LFS 必須 |
| Balanced | `SRVGGNet_x2.mlmodelc`      | `SRVGGNet_x2.onnx`      | 自前学習(蒸留)。LFS 必須 |
| Quality  | `RealESRGAN_x2.mlmodelc`    | `RealESRGAN_x2.onnx`    | 公開重みから再生成可 |

---

## 5. ディレクトリ構成まとめ

```
~/Library/Application Support/Bubilator88/
├── N88.ROM, N80.ROM, DISK.ROM, ...    ROM ファイル
├── KANJI1.ROM, KANJI2.ROM             漢字ROM
├── 2608_BD.WAV, ...                   リズム音源
└── SaveStates/
    ├── quicksave.b88s
    ├── quicksave.meta.json
    ├── quicksave.thumb.png
    ├── slot_0.b88s ... slot_9.b88s
    ├── slot_0.meta.json ...
    └── slot_0.thumb.png ...
```
