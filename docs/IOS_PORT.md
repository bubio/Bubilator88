# iOS/iPadOS 対応プラン

Bubilator88 を iPhone / iPadOS でも動かす構想と、その実現可能性の机上調査結果。
`docs/WINDOWS_PORT.md` がコア DLL 化+ネイティブシェル新規実装という方針だったのに対し、
iOS の場合は **言語・UI フレームワークが同じ (Swift / SwiftUI)** であるため事情が異なる。

> このドキュメント自体が「調査から実装への引き継ぎ」を兼ねる。次にこの対応に
> 着手するときは、ここを起点に Phase 0 から進める。

---

## 1. 基本方針(最重要)

**EmulatorCore (pure Swift package) はそのまま再利用する。**

- macOS と iOS は同じ Swift toolchain / Apple SDK 系列なので、Windows ポートのような
  「コアを DLL 化して別言語シェルから P/Invoke で叩く」構成は不要。
- App 層 (SwiftUI) も大半は条件分岐 (`#if os(macOS)` / `#if os(iOS)`) で共有できる。
  AppKit 専用箇所 (NSEvent, NSCursor, CommandMenu, 複数 Window シーン等) だけを
  iOS 版の実装に置き換える「マルチプラットフォーム単一ターゲット」方式を取る。
- スコープは **iPhone / iPadOS 両対応**。BT キーボード・MFi/BT ゲームコントローラは
  iPhone でも通常使えるため、「iPhone はタッチのみ」という前提は置かない。
  両プラットフォームで **BT キーボード/コントローラを一次入力**、
  **オンスクリーンソフトウェアキーボードを補助入力**として併用する。

```
┌─────────────────────────────┐    ┌─────────────────────────────┐
│  macOS App (SwiftUI/AppKit) │    │  iOS/iPadOS App (SwiftUI)   │
│  Metal(NSViewRepresentable) │    │  Metal(UIViewRepresentable) │
│  NSEvent / NSCursor 入力     │    │  GCKeyboardInput/GCMouse 入力│
│  CommandMenu / 複数Window    │    │  ツールバー+シート / Window  │
└──────────────┬──────────────┘    └──────────────┬──────────────┘
               │                                   │
               ▼                                   ▼
        ┌───────────────────────────────────────────────┐
        │  EmulatorCore (pure Swift, 単一ソース・無変更)  │
        │  Z80 / FMSynthesis / Peripherals / Core        │
        │  Package.swift platforms に .iOS を追加するのみ │
        └───────────────────────────────────────────────┘
```

---

## 2. フィージビリティ調査結果 (2026-06-23)

| 領域 | 判定 | 詳細 |
|---|---|---|
| EmulatorCore (Z80/FMSynthesis/Peripherals/EmulatorCore) | ✅ そのまま再利用 | pure Swift、Foundation + swift-log のみ依存。`Package.swift` に `.iOS` 追加するだけ |
| `Input/KeyMapping.swift` | ✅ ほぼ再利用 | プラットフォーム依存なし。iOS 用キーコード変換を追加するだけ |
| `Input/ControllerHaptics.swift` / `HeadTrackingManager.swift` | ✅ そのまま再利用 | CoreHaptics / CoreMotion は iOS でも利用可能 |
| `Rendering/AIUpscaler.swift` (CoreML) | ✅ そのまま再利用 | CoreML は iOS 対応 |
| `Rendering/Display.metal` | ✅ そのまま再利用 | MSL はプラットフォーム非依存 |
| `Rendering/EmulatorMetalView.swift` | 🟡 条件付き | `MTKView` 自体は iOS でも動作。NSView 特有の呼び出し (tracking area 等) があれば分離 |
| `Rendering/MetalScreenView.swift` | 🟡 条件付き | `NSViewRepresentable` → iOS は `UIViewRepresentable` に分岐 |
| `Audio/AudioOutput.swift` (AVAudioEngine) | 🟡 条件付き | iOS は `AVAudioSession` の category/activate が必須 (macOS には存在しない概念) |
| `Views/SoftwareKeyboardView.swift` / `KeyCapButton.swift` | 🟡 軽微修正 | `Color(nsColor:)` → プラットフォーム分岐。構造自体はタップでキーを送るだけで iOS の主力入力になり得る |
| `Input/KeyEventView.swift` | 🔴 書き直し | `NSEvent` ローカルモニタ、`CGAssociateMouseAndMouseCursorPosition`、`NSCursor` は iOS に存在しない。GameController framework の `GCKeyboardInput`/`GCMouseInput` で置き換え |
| `Input/GameControllerManager.swift` | 🟡 条件付き | コア (GCController 監視) は共通。`postHostShortcut` (NSEvent 合成によるメニューショートカット送信) は macOS 専用に隔離 |
| `App/Bubilator88App.swift` (Scene/Commands) | 🔴 書き直し | `CommandMenu`/`CommandGroup`/`SwiftUI.Settings`/複数 `Window` シーン/`NSHelpManager` は iOS に概念がない。メニュー項目が呼ぶ `viewModel.xxx()` 自体は再利用可能 — UI の入れ物だけ作り直す |
| `App/AppDelegate.swift` | 🔴 iOS 不要 | `NSApplicationDelegateAdaptor` は macOS 専用。iOS は素の `App` プロトコルで足りる |
| `Views/` 配下その他 (AboutView 等) | 🟡 軽微修正 | `NSImage`/`NSColor` 等のピンポイント箇所のみ分岐 |
| `Utilities/ArchiveExtractor.swift` | 🔴 機能縮小 (合意済み) | LZH/CAB/RAR は `Process()` (bsdtar/unar/unrar/7z) 依存で iOS では実行不可。**iOS は ZIP のみ対応**とし、LZH/CAB/RAR は macOS 限定機能として残す |
| ROM/ディスク/セーブステートの保存先 (`~/Library/Application Support/Bubilator88/`) | 🟡 UX 追加が必要 | `FileManager.applicationSupportDirectory` 自体は iOS でもサンドボックス内で有効。ただし Finder からのドラッグ配置に相当する手段が iOS にはないため、初回起動時の ROM 取り込み UI (fileImporter) が新規に必要 |
| Xcode プロジェクト設定 | 🔴 要追加 | `SUPPORTED_PLATFORMS`/`IPHONEOS_DEPLOYMENT_TARGET` が未設定。マルチプラットフォーム ("Destinations") ターゲットへ変更が必要 |
| `EmulatorCoreTests` / `BootTester` | ✅ 無影響 | pure Swift のため、コア側の regression 保護は iOS 対応作業中も変わらず機能する |

---

## 3. 実装計画

### Phase 0 — 土台 (ビルド可能な最小状態)
- `Packages/EmulatorCore/Package.swift` の `platforms` に `.iOS(.v18)` を追加し、
  iOS シミュレータ向けビルド (`swift build -triple arm64-apple-ios18.0-simulator` 等) で
  Darwin 隠れ依存が無いか確認。pure Swift のため通る想定。
- `Bubilator88.xcodeproj` に iOS Destination を追加 (Xcode 16+ の「マルチプラットフォーム
  アプリ」変換、または `TARGETED_DEVICE_FAMILY`/`SUPPORTED_PLATFORMS = "iphoneos
  iphonesimulator"` の手動追加)。既存 macOS ターゲットはそのまま、共有ファイルの大半は
  target membership を両方に付与し `#if os(iOS)` / `#if os(macOS)` で分岐する方針
  (ファイル複製を避ける)。

### Phase 1 — 入力レイヤー
- `Input/KeyMapping.swift` に iOS 用マッピングを追加。BT キーボード入力は
  **GameController framework の `GCKeyboardInput`** (`GCKeyboard.coalesced?.keyboardInput`)
  を使う方針 — すでに `GameControllerManager.swift` で GameController framework を
  使っており、`NSEvent` ベースの自前モニタを書く必要がなくなる。
  `GCKeyboardInput.keyChangedHandler` で `GCKeyCode` → PC-8801 行列への
  マッピングテーブルを `KeyMapping.swift` に追加。
- マウスは `GCMouse.current` (`GCMouseInput.mouseMovedHandler` で相対デルタ取得) を使用。
  `CGAssociateMouseAndMouseCursorPosition`/`NSCursor.hide()` 相当の処理は不要 —
  `GCMouse` は OS カーソルと独立して相対移動量を渡す。
- `KeyEventView.swift` は `#if os(macOS)` で現状維持、iOS 用に新規ファイル
  (例: `KeyEventView+iOS.swift`) を追加して `GCKeyboardInput`/`GCMouseInput` 監視 +
  `SoftwareKeyboardView` タップ入力を `EmulatorViewModel.pressKey/releaseKey` に渡す。
- `GameControllerManager.swift` の `postHostShortcut` (NSEvent 合成によるメニュー操作) は
  `#if os(macOS)` で隔離。コア (GCController 接続監視、ボタン→PC88入力マッピング) は共通化。
- `SoftwareKeyboardView.swift` / `KeyCapButton.swift` の `Color(nsColor:)` を
  `#if os(iOS) Color(uiColor: .systemBackground) #else Color(nsColor: .windowBackgroundColor)
  #endif` に分岐。これ以外は無修正で両プラットフォームの主力 (BTキーボード未接続時)
  入力として使える。

### Phase 2 — レンダリング
- `MetalScreenView.swift` を `#if os(macOS) NSViewRepresentable #else UIViewRepresentable
  #endif` で分岐。`EmulatorMetalView` (MTKView サブクラス) 自体はプラットフォーム共通
  コードとして極力維持し、AppKit 専用呼び出し (もしあれば) のみ条件分岐。
- `Display.metal` は変更不要。

### Phase 3 — 音声
- `AudioOutput.swift` に `#if os(iOS)` ブロックを追加し、
  `AVAudioSession.sharedInstance().setCategory(.playback)` + `setActive(true)` を
  エンジン起動前に実行。
- iOS のオーディオ中断 (電話着信等) に対応するため `AVAudioSession.interruptionNotification`
  を監視し、中断終了時にエンジンを再起動する処理を追加 (macOS には無い概念なので新規)。

### Phase 4 — アプリシェル (Scene/UI 再設計)
- `Bubilator88App.swift` は丸ごと iOS 版を新規作成 (`#if os(iOS)` で完全に別の `body` を
  構築するか、ファイル自体を `Bubilator88App+macOS.swift` / `Bubilator88App+iOS.swift` に
  分離して `@main` を条件分岐)。
  - メニューバー (`CommandMenu`) が存在しないため、各メニュー項目が呼んでいる
    `viewModel.xxx()` をツールバー + シートで束ねた「コントロールセンター」シートを
    新設 (Disk / Tape / Display / Audio / Save State の各タブ)。ボタンのアクション本体は
    そのまま `EmulatorViewModel` の既存メソッドを再利用。
  - 複数 `Window` シーン (Debugger / Software Keyboard) は iPadOS では SwiftUI の
    `Window`/`openWindow` がマルチシーンとして機能する (iPadOS 16+) ためほぼそのまま
    使える。iPhone では画面が一つしかないため `sheet`/`NavigationStack` 経由の
    プッシュ表示に変更。
  - `SwiftUI.Settings { }` (macOS 専用 Settings シーン) は iOS では使えないため、
    設定画面を通常の `NavigationLink` 遷移先 (既存の `SettingsView` をそのまま埋め込み) に
    変更。
  - `NSHelpManager` によるヘルプ表示は iOS では `SFSafariViewController` 等で
    オンラインヘルプページを開く形に置き換え、または Phase 4 では割愛してよい (優先度低)。
- `AppDelegate.swift` は iOS では不要。iOS 版は素の `App` 準拠 struct から直接
  `EmulatorViewModel` を初期化する。
- BT キーボードのショートカット (⌘S クイックセーブ等) は `UIResponder.keyCommands`
  (`UIKeyCommand`) で同等のショートカットを定義し、既存の `viewModel` メソッドに
  バインドして macOS と操作感を揃える。

### Phase 5 — ファイル/永続化
- ROM (`N88.ROM` 等) の配置を、初回起動時に表示する `fileImporter` ベースの
  「ROM 取り込み」画面で `~/Library/Application Support/Bubilator88/` (iOS でも
  サンドボックス内に存在する同名ディレクトリ) へコピーする処理を新規実装。
  `docs/PERSISTENCE.md` のパス構造自体は変更不要。
- ディスク/テープのマウントは `EmulatorViewModel+Disk.swift` / `+Tape.swift` が既に
  `startAccessingSecurityScopedResource()` を使っている (macOS サンドボックス対応の
  既存実装) ため、iOS の `UIDocumentPickerViewController`/`fileImporter` 経由でも
  そのまま流用できる見込み。実機/シミュレータで動作確認のみ必要。
- `ArchiveExtractor.swift` に `#if os(iOS)` を追加し、`extractWithBsdtar`/`extractRAR` の
  `Process()` 呼び出し経路を iOS ではスキップ (ZIP 検出 + `extractZIP` のみ到達するように
  する)。LZH/CAB/RAR は iOS 版では「対応外」として UI 側にメッセージを出す。
- セーブステート (`SaveStateSheetView.swift`) はパス構造が `applicationSupportDirectory`
  ベースで共通なので追加対応不要。

### Phase 6 — Xcode プロジェクト/配布設定
- `Info.plist` に iOS 用キーを追加: `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`
  (Files app から `.d88`/`.b88script` を開けるように)、`UISupportedInterfaceOrientations`
  (横画面固定を推奨 — PC-8801 画面比率は横長)。
- バックグラウンド挙動: `scenePhase` を監視し、バックグラウンド遷移時にエミュレーションを
  一時停止 (`viewModel.pause()`)、フォアグラウンド復帰時に `resume()`。常時音声再生が
  必要な要件は現状なさそうなので `UIBackgroundModes` の audio 許可は不要と判断
  (将来要件が出たら追加)。

### Phase 7 — テスト
- `EmulatorCoreTests` (777 tests) と `BootTester` は pure Swift のため無変更で
  iOS 対応作業中も regression ガードとして機能する。Phase 0〜6 の各ステップ後に
  `cd Packages/EmulatorCore && swift test` を実行して既存挙動に影響がないことを確認。
- iOS 版 UI の動作確認は実機/シミュレータでの手動確認 (`/run` スキルまたは Xcode 直接実行)
  で行う。新規 XCUITest ターゲットの追加は本計画の対象外 (必要になった時点で別途検討)。

---

## 4. 主要変更ファイル (代表例)

- `Packages/EmulatorCore/Package.swift` — `platforms` に iOS 追加
- `Bubilator88/App/Bubilator88App.swift` — iOS 用シーン構成を追加 (大規模書き直し)
- `Bubilator88/App/AppDelegate.swift` — `#if os(macOS)` で隔離
- `Bubilator88/Input/KeyEventView.swift`, `KeyMapping.swift`, `GameControllerManager.swift`
  — GCKeyboardInput/GCMouseInput 経由の iOS 入力パス追加
- `Bubilator88/Rendering/MetalScreenView.swift` — UIViewRepresentable 分岐
- `Bubilator88/Audio/AudioOutput.swift` — AVAudioSession 追加
- `Bubilator88/Utilities/ArchiveExtractor.swift` — iOS は ZIP のみに制限
- `Bubilator88/Views/SoftwareKeyboardView.swift`, `KeyCapButton.swift`, `AboutView.swift`
  — NSColor/NSImage の条件分岐
- `Bubilator88.xcodeproj/project.pbxproj` — iOS Destination 追加

---

## 5. 検証方法

- 各 Phase 完了時に `cd Packages/EmulatorCore && swift test` (既存 530+ テストが green
  であること)。
- iOS シミュレータ (iPhone / iPad) でビルド・起動し、ソフトウェアキーボードでの起動シーケンス
  (N88-BASIC cold boot 等) が動作することを確認 (`docs/BOOTTESTER.md` のキー操作と同等の
  手順を実機 UI で再現)。
- BT キーボード/コントローラ実機 (またはシミュレータの Hardware > Keyboard 連携) で
  `GCKeyboardInput`/`GCMouseInput` 経由の入力が PC-8801 キー行列に正しく反映されることを
  確認。
- macOS 版の既存 regression スイート (`scripts/regression_compare.py`, 15 シナリオ) を
  Phase 0〜2 完了時点で再実行し、共有コード分岐 (`#if os(macOS)`) の追加が既存 macOS
  挙動を壊していないことを確認。
