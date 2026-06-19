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
