# Windows ネイティブ版 移植プラン

Bubilator88 を **Windows ネイティブ機能**(クロスプラットフォーム技術ではなく)で
移植する構想と、その実現可能性の机上監査結果。macOS 側の調査でわかったことを
Windows 環境で読んで作業を再開できるようにまとめる。

> このドキュメント自体が「会話の引き継ぎ」を兼ねる。Windows で `git pull` 後、
> ここを起点に作業を始められる。

---

## 1. 基本方針(最重要)

**エミュレーションコア (EmulatorCore) は絶対に書き直さない。**

- 本プロジェクトの価値は 200+ ユニットテストと `docs/KNOWN_PITFALLS.md` に積み上がった
  **挙動精度**にある。コアを C++/C# で二重実装すると両者が必ず divergし、
  「mac では起動するが Windows では起動しない」地獄になる。エミュレータで最悪のパターン。
- したがって **EmulatorCore は Swift 単一ソースのまま**にし、Windows でも
  Swift toolchain でビルドする。`@_cdecl` で C ABI を export して
  **ネイティブ DLL** にする。
- **シェル (App 層) だけを Windows ネイティブで新規実装**し、P/Invoke でコア DLL を叩く。
  シェル言語は **C# + WinUI 3(または WPF)** が productivity 的に最有力。

```
┌─────────────────────────────┐    ┌─────────────────────────────┐
│  macOS App (SwiftUI/AppKit) │    │ Windows Shell (C# + WinUI 3)│
│  Metal / AVFoundation / ... │    │ D3D11 / WASAPI / XInput ... │
└──────────────┬──────────────┘    └──────────────┬──────────────┘
               │                                   │ P/Invoke
               ▼                                   ▼
        ┌───────────────────────────────────────────────┐
        │  EmulatorCore (pure Swift, 単一ソース)         │
        │  Z80 / FMSynthesis / Peripherals / Core        │
        │  → macOS は static link, Windows は @_cdecl DLL │
        └───────────────────────────────────────────────┘
```

---

## 2. 移植性監査の結論(2026-06-20, macOS 上で実施)

**EmulatorCore の Windows 移植性は極めて良好。** Foundation / プラットフォーム API 依存を
全ライブラリターゲット (Z80 / FMSynthesis / Peripherals / EmulatorCore) で1ファイルずつ
監査した結果、コンパイルを止める要因は **1点のみ**だった(下記、対応済み)。

### 🔴 唯一のブロッカー → 対応済み (commit e0632c1)

`FMSynthesizer.swift` と `Peripherals/UPD1990A.swift` が C 数学関数
(`pow`/`sin`/`cos`/`log`/`log2`/`floor`)を **Darwin.C / Glibc からしか**取っておらず、
Windows 分岐が無かった。特に `FMSynthesizer.swift` は Foundation 未 import で
数学を完全に libc 依存だったため、Windows では FM 音色テーブル生成と YM2608 ADPCM
テーブルが全滅していた。

`#elseif canImport(ucrt) / import ucrt`(Windows Universal CRT)と
`#elseif canImport(Musl) / import Musl`(静的 Linux)を追加して**修正済み**。
macOS は `canImport(Darwin)` が先行するため無影響(build 確認済み)。

### 🟢 確認済み・問題なし

| 項目 | 結論 |
|---|---|
| `Data` / `String(format:)`×126(hexダンプ)/ `Date` / `NSLock`×1 | Windows Foundation で対応済み |
| `FileHandle` / `FileManager` / `URL` | ライブラリでは `MemoryDump.swift` と `Debugger/Debugger.swift` の**デバッグ専用2ファイルのみ**。DLL 本筋(`runFrame`・ピクセルバッファ・セーブステート)には不要 |
| 依存 `swift-log` (Logging) | Apple 公式・完全クロスプラットフォーム |
| `os_unfair_lock` / `DispatchQueue` / Mach / CoreFoundation | **ライブラリ本体にゼロ**。`CFAbsoluteTimeGetCurrent` は BootTester (CLI) のみ |
| `Package.swift platforms: [.macOS(.v15)]` | Apple 最低 OS 宣言にすぎず Windows ビルドを妨げない。**変更不要** |

> セーブステート / D88 ディスク / FM 音源コアは `Data` ベースで Foundation 移植範囲内。
> **移植不要でそのまま動く**見込み。

---

## 3. 残タスク(Windows 環境でやること)

机上で潰せる静的リスクは §2 のパッチで尽きた。以降は実機作業。

1. **Windows に Swift toolchain を入れ、`swift build` / `swift test` を回す。**
   グリーンになれば移植の8割は勝ち確。`String(format:)` の `%ld`/`%lu` 幅指定子が
   LLP64 で稀に挙動差を出しうるが、デバッグ出力なのでエミュ精度には無関係。
2. **最小 DLL の vertical slice。** `runFrame` + ピクセルバッファ取得 + キー入力 +
   ディスクマウントだけ `@_cdecl` で export し、**C# から D3D で 640×400 を1枚出す**。
   ここが動けば残りは各機能を埋めるだけの作業になる。
3. 各機能を順次移植(§4)。

### Vertical slice 実装状況(2026-06-20, スキャフォールド済み)

決定: **シェル = C# + WinUI 3(GC対策)**、コア = Swift→DLL。コード一式を配置済み
(Windows 実機での build/run 検証は未。Swift toolchain と Windows App SDK 環境が要る)。

- **コア側 DLL シム**: `Packages/EmulatorCore/Sources/CApi/CApi.swift` 新規。opaque handle で
  `Machine` を包み、`b88_create/run_frame/render_rgba/press_key/mount_disk/...` を `@_cdecl` export。
  **ピクセル合成ロジック(`EmulatorViewModel+Rendering.swift` の `renderCurrentFrame` +
  パレット純関数)を移植して `b88_render_rgba` に内蔵** — C# はパレット計算を持たず diverg を断つ。
  `Package.swift` に `.library(type:.dynamic, name:"Bubilator88C")` + `CApi` target 追加。
  Windows シンボル公開は `Sources/CApi/Bubilator88C.def`(linkerSettings, Windows 限定)。
- **シェル側**: `windows/Bubilator88.Windows/`。`NativeApi.cs`(P/Invoke)/`EmulatorHost.cs`
  (再利用バッファ)/`D3DScreen.cs`(SwapChainPanel+D3D11+nearest HLSL)/`XAudioSink.cs`
  (XAudio2)/`KeyMapping.cs`(VirtualKey→マトリクス)/`MainWindow`(60Hzループ+入力+マウント)。
  ビルド手順は `windows/README.md`。
### 実機検証済み(2026-06-20, Windows 11 / Swift 6.3.2 swift-6.3.2-RELEASE / x86_64-windows-msvc)

Swift toolchain を導入して実ビルド。**コア→DLL パイプラインがフルに通った。**

- ✅ `swift build` 全ターゲット成功(Z80 / FMSynthesis / Peripherals / EmulatorCore / CApi / BootTester)。
- ✅ `swift test` **760/760 パス**(29 suites)。挙動精度が macOS と同一であることを Windows で実証。
- ✅ `swift build -c release --product Bubilator88C` → `Bubilator88C.dll`(~5MB)リンク成功。
- ✅ `dumpbin /exports` で `b88_*` **14 シンボルがクリーン名で公開**(`.def` 経由)を確認。
- DLL は `windows/Bubilator88.Windows/native/Bubilator88C.dll` に配置済み。

#### 机上監査が見落としていた実ブロッカー(2件・修正済み)

§2 の机上監査では math だけが挙がっていたが、実ビルドで追加2件が出た。いずれも修正済み:

1. **`Peripherals/UPD1990A.swift`** RTC の `localtime_r`(POSIX)が ucrt に無い。
   `#if os(Windows)` で `localtime_s(&cal, &t)`(**引数順が逆**)に分岐。結果は同一。
2. **`BootTester/main.swift`** の `CFAbsoluteTimeGetCurrent`(CoreFoundation)が Windows 非対応。
   `Date().timeIntervalSinceReferenceDate`(同じ 2001 基準秒・Foundation クロスプラットフォーム)へ置換 ×6。

> 教訓: 「Foundation 互換だから動く」の机上判断は **libc/CoreFoundation 直叩き**を取りこぼす。
> ライブラリ単位の grep より **実 `swift build` 一発**の方が速く確実。

#### C# シェルも実機起動成功(2026-06-20)

- ✅ `dotnet build -c Release -r win-x64` 成功(.NET 10 / Windows App SDK 1.6 / Vortice 3.6)。
- ✅ 実起動して **N88-BASIC コールドブート画面**(`How many files(0-15)?` + F-key 表示)を 640×400 で確認。
  Swift コア DLL → P/Invoke → `b88_run_frame`/`b88_render_rgba` → D3D11 nearest 表示の全経路が画素レベルで正常。
- C# 側ではまった点(修正済み):
  1. csproj の XML コメントに `--`(`--product`)は不正 → 文言修正。
  2. Vortice 3.6 API: `AudioBuffer.AudioBytes` は `uint`、`Compiler.Compile` は `ReadOnlyMemory<byte>` を返す(`.Span`)。
  3. `WindowsAppSDKSelfContained` は RID 必須 → `dotnet build/run -r win-x64`。
  4. **DLL 配置**: `None Include="native\..."` を `<Link>Bubilator88C.dll</Link>` で**出力直下**に置かないと
     P/Invoke が `ERROR_MOD_NOT_FOUND (0x8007007E)` で落ちる(native\ サブフォルダは探索対象外)。
- ランタイム: `Bubilator88C.dll` は Swift ランタイム DLL(`...\Swift\Runtimes\6.3.2\usr\bin`)に依存。
  開発機は同 bin が PATH 上で解決。**配布時は同梱が要る**(未対応)。

#### 残(v1 以降)

- キー入力・`.d88` ゲーム起動の実操作確認、§4 の各機能移植(フィルタ/コントローラ/マウス/セーブステート/AI/OCR)。

### フル機能移植 完了(2026-06-25)

vertical slice 以降、§4 マッピングの大半を実装。シェルは macOS とほぼパリティ
(残りは §4 で「未実装」とした周辺機能のみ)。実装は `windows/Bubilator88.Windows/`、
ビルド/チェックアウト/モデル生成の手順は `windows/README.md`。

- **映像**: D3D11 で None/Linear/Bicubic/CRT/xBRZ/Enhanced/**AI (Fast/Balanced/Quality)** の
  フィルタ + スキャンライン。ウィンドウ ×1/×2/×4(固定・永続)、フルスクリーン整数スケーリング、
  レターボックス。
- **AI アップスケール**: CoreML の代わりに **ONNX Runtime + DirectML** で、macOS と同じ
  3 モデル(Fast=`SRVGGNet_x2_lite` / Balanced=`SRVGGNet_x2` / Quality=`RealESRGAN_x2`)を
  実行。フィルタ切替でモデルを載せ替え(`AiUpscaler` を該当モデル名で再生成)。非同期ダブル
  バッファ、`generation` で stale 破棄、未準備/モデル不在/DirectML 不在時は Bicubic フォール
  バック(`AiUpscaler.cs`、macOS の state machine と同型)。FPS 表示は AI 時に推論スループットを
  報告(macOS パリティ)。**3 モデルとも単一の source-of-truth `.pth`(`models/`, Git LFS)から
  macOS=CoreML / Windows=ONNX の二形式に生成される**(§4 参照)。
- **音声**: XAudio2 リングバッファ + 適応レート制御、既定デバイスフォーマット追従、リズム音源サンプル読込。
- **ディスク**: マルチイメージ D88、Drive 1/2/1&2、ライトプロテクト、Recent Files、イメージ選択ダイアログ。
- **入力**: VirtualKey→マトリクス(US/JIS 記号、矢印/数字行/WASD テンキー擬似)。メニューの
  キーボードショートカット(画面が文字キーを食う問題を `OnKeyDown` で chord ディスパッチして解決)。
  メニュー閉/音量スライダー操作後にエミュビューへフォーカス復帰。
- **状態保存**: セーブステート(スロット/クイック+メタ+サムネイル)、スクリーンショット(PNG/JPEG/HEIC)、CPU 早送り ×1〜×16。
- **設定**: General/Display/Audio/Keyboard タブを持つ設定ダイアログ(`settings.json` 即時永続化)。
- **テスト基盤**: `windows/Bubilator88.Windows.Tests`(xUnit)。self-contained WinUI exe を
  ProjectReference できないため、UI 非依存の純ロジック(`KeyMapping`/`PixelMath`)をソースリンクして検証。

#### Git LFS

AI モデルは全 OS 共有の `models/onnx/*.onnx` に集約し、Windows csproj がここから出力直下へ
コピーする(将来の Linux シェルも同じ場所を使う)。git 履歴肥大を避けるため `.pth` / `.onnx` は
**Git LFS** で管理(`.gitattributes`: `*.onnx` / `*.pth filter=lfs`)。clone 後は `git lfs pull`
で実体化が必要(未 pull はポインタ ~133B → 該当 AI フィルタは Bicubic フォールバック)。

- **自前学習の SRVGGNet(Fast/Balanced)は必ず LFS で commit** — 公開重みが無く、`.pth` を失うと
  誰も再生成できない。source-of-truth の `.pth`(`models/*.pth`)も LFS でリポジトリに取り込み済。
- **RealESRGAN(Quality)は公開重みから再生成可能**なので commit は任意
  (`scripts/convert_realesrgan_onnx.py`)。

取得・生成手順は `windows/README.md`、再学習の完全手順は `models/PROVENANCE.md` 参照。

---

## 4. 機能ごとの移植マッピング

| 現状 (macOS) | Windows ネイティブ | 状況 |
|---|---|---|
| EmulatorCore (Swift) | **そのまま**(Swift → DLL, `@_cdecl` C ABI) | ✅ 実機 build + 760 test 検証済 |
| Metal + `Display.metal` | Direct3D 11 + HLSL | ✅ 7フィルタ + スキャンライン |
| AVAudioEngine リングバッファ | XAudio2(リング部のロジックは流用) | ✅ 適応レート制御込み |
| KeyEventView + KeyMapping | WinUI `KeyDown` / VirtualKey ※マッピングテーブル全書き換え | ✅ US/JIS + テンキー擬似 + メニュー chord |
| xBRZ GPU シェーダ | HLSL シェーダへ移植 | ✅ |
| AIUpscaler (CoreML, RealESRGAN/SRVGGNet) | ONNX Runtime + DirectML(`.pth`→ONNX 変換、共有 `models/onnx/`) | ✅ 3 モデル対応(Fast/Balanced=SRVGGNet, Quality=RealESRGAN) |
| セーブステート / D88 / スクショ / 早送り | コア内 + ホスト I/O | ✅ |
| GameController (GCController) | Windows.Gaming.Input.Gamepad(ポーリング方式、単一グローバルマッピング) | ✅ 実装済(`windows/Bubilator88.Windows/GameController/`) |
| ControllerHaptics (CoreHaptics, SSGノイズ検出) | Windows.Gaming.Input.Gamepad.Vibration | ⬜ 未実装(EmulatorCore の CApi 拡張が必要、別PRで対応予定) |
| マウスロック (`CGAssociateMouseAndMouseCursorPosition`) | `ClipCursor` + RAWINPUT 相対デルタ | ⬜ 未実装 |
| OCR 翻訳 (Vision) | Windows.Media.Ocr | ⬜ 未実装 |
| FDDSound (AVAudioEngine 別エンジンでの合成シーク/リード音) | XAudio2 の専用エンジン(メイン音声とは別)、出力デバイス個別選択は `NAudio.CoreAudioApi.MMDeviceEnumerator` で列挙 | ✅ 実装済(出力デバイス選択込み) |
| Apple Help Book / 空間オーディオ / ヘッドトラッキング / 録画 | 削るか別実装(任意) | ⬜ 未実装 |

**「全部は無理でも近いものに」**は妥当な見立てだった。コア・描画・音・ディスク・セーブステート・
AI アップスケールまで高再現で移植済み。残るは ゲームコントローラ / マウスロック / OCR 翻訳 /
空間オーディオ等の「Windows なりの別実装 or 省略」枠のみ。

---

## 5. 参考

- アーキテクチャ全体: `docs/ARCHITECTURE.md`(モジュール依存、T-state タイミング、レンダリング/オーディオパイプライン)
- 挙動精度の落とし穴: `docs/KNOWN_PITFALLS.md`
- CLI テストハーネス: `docs/BOOTTESTER.md`(コア単体のリグレッション検証に使える)
