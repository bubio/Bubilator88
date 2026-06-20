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

---

## 4. 機能ごとの移植マッピング

| 現状 (macOS) | Windows ネイティブ | 難易度 |
|---|---|---|
| EmulatorCore (Swift) | **そのまま**(Swift → DLL, `@_cdecl` C ABI) | ★ 実機 build 検証要 |
| Metal + `Display.metal` | Direct3D 11 + HLSL(passthrough nearest) | ★ 容易 |
| AVAudioEngine リングバッファ | WASAPI または XAudio2(リング部のロジックは流用) | ★ 容易 |
| GameController (GCController) + haptics | XInput / Windows.Gaming.Input(振動含む) | ★★ |
| KeyEventView + KeyMapping | Win32 `WM_KEYDOWN` / Raw Input ※マッピングテーブル全書き換え | ★★ |
| マウスロック (`CGAssociateMouseAndMouseCursorPosition`) | `ClipCursor` + RAWINPUT 相対デルタ | ★★ |
| xBRZ GPU シェーダ | HLSL compute シェーダへ移植 | ★★ |
| AIUpscaler (CoreML, RealESRGAN/SRVGGNet) | ONNX Runtime + DirectML(モデルを ONNX 変換) | ★★★ |
| OCR 翻訳 (Vision) | Windows.Media.Ocr | ★★ |
| セーブステート / D88 | コア内なので**移植不要** | — |
| Apple Help Book / 空間オーディオ / ヘッドトラッキング | 削るか別実装(任意) | — |

**「全部は無理でも近いものに」**は妥当な見立て。コア・描画・音・ディスク・セーブステートは
高再現で移植でき、CoreML アップスケールと OCR 翻訳と空間オーディオが
「Windows なりの別実装 or 省略」枠になる。

---

## 5. 参考

- アーキテクチャ全体: `docs/ARCHITECTURE.md`(モジュール依存、T-state タイミング、レンダリング/オーディオパイプライン)
- 挙動精度の落とし穴: `docs/KNOWN_PITFALLS.md`
- CLI テストハーネス: `docs/BOOTTESTER.md`(コア単体のリグレッション検証に使える)
