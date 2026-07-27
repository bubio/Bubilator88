# URL スキーム起動 実装計画 (FlipDisk 連携 / xm8 CLI 相当)

> **注意 (2026-07-27 更新)**: 本書は初版の設計記録。**引数の書式はその後
> QUASI88 互換 (`arg` クエリ項目の繰り返し = argv) に変更され、CLI 起動にも
> 対応した**。`disk0`/`bank0`/`disk1`/`bank1`/`system`/`clock` クエリは廃止。
> 現行仕様は [URL_SCHEME.md](URL_SCHEME.md) を参照。単一インスタンス差し替え・
> 全件検証してから mount というセマンティクスは変わっていない。

Sonnet 実装用の計画書。FlipDisk（自前ランチャー）から Bubilator88 を起動し、
xm8 の CLI 仕様（最大2枚の D88 + bank + system + clock）と**同じセマンティクス**で
ゲームをブートする。**単一インスタンスでディスクを差し替える**（新ウィンドウを
乱立させない）。

---

## 1. アーキテクチャ決定と根拠

### 1.1 なぜ argv ではなく URL スキームか（確定）

xm8 は SDL の `int main(argc, argv)` なので argv 直渡しでよいが、Bubilator88 は
SwiftUI の `.app`。macOS では：

- `open -a App --args …` の引数は **新規起動時しか argv に届かない**。**起動中の
  インスタンスには一切渡らない**（既存ウィンドウを前面化するだけ）。
- 「単一インスタンス差し替え」を選んだ以上、起動中インスタンスへ情報を届ける
  唯一の正規手段は **Apple Event**（ドキュメントオープン or カスタム URL スキーム）。
- オプション（system/clock/bank/2枚）を搬送できるのは URL スキームのみ
  （ドキュメントオープンはファイルパスしか運べない）。

→ **カスタム URL スキーム `bubilator88://` を transport にする。**
既存の `.onOpenURL`（`.b88script` 用）がコールド/ウォーム両対応の配管を
持っているので、それをそのまま流用できる。

### 1.2 xm8 の「構文」は移植しない。「意味」だけ踏襲する（確定）

`clidisk.cpp` の argv トークナイザ（`#`/`:`/`--`/quote/Windows ドライブ解析）は
**平文字列 argv だから必要なだけ**。こちらはプログラム（FlipDisk）が構造化 URL を
組むので、`#bank` パースは不要 → query param に分解する。

踏襲する **xm8 セマンティクス**（`docs`/xm8 README §3）:

- 位置ディスクは**最大2枚**、順に drive 0 / drive 1。
- bank は **0 始まり**。省略時 0。
- **全 disk-spec を検証してから mount を開始**。1件でも検証・mount 失敗なら
  **現状を一切変えずアプリ状態を保つ**（xm8 は「起動しない」だが、こちらは
  既に走っている単一インスタンスなので「**差し替えを中止して元のまま**」）。
- 存在しない bank は**エラー**（最終 bank への丸め込み禁止）。

**踏襲しない**: literal argv パース。ターミナルから `bubilator88 game.d88` を
叩く用途は今回スコープ外（単一インスタンス差し替えを選んだ時点で running
instance には argv が届かないので、二重実装は死にコードになる）。

### 1.3 system/clock は永続化する（確定・ユーザ決定）

xm8 は「セッション限定・終了時 restore」だが、本実装は **URL で来た
system/clock を通常の設定として `Settings.shared` に保存する**。理由:

- FlipDisk は**毎回ゲームごとに system/clock を指定する**ので、次回起動で
  上書きされる → 永続化による実害がない。
- Bubilator88 の `bootMode` / `clock8MHz` setter も `adoptScriptSetup` も
  元々すべて `Settings.shared` へ書く作りなので、永続化が自然でコードが最小。
- snapshot/restore を @Observable な Settings に組むと壊れやすい（回避）。

---

## 2. URL フォーマット仕様（FlipDisk ↔ Bubilator88 の契約）

```
bubilator88://boot?disk0=<path>&bank0=<n>&disk1=<path>&bank1=<n>&system=<sys>&clock=<clk>
```

| query key | 必須 | 値 | 説明 |
|-----------|------|----|------|
| `disk0` | ○ | percent-encoded 絶対パス | drive 0 に載せる D88（または .m3u） |
| `bank0` | × | 0 以上の10進 | drive 0 の面(imageIndex)。省略時 0 |
| `disk1` | × | percent-encoded 絶対パス | drive 1 に載せる D88 |
| `bank1` | × | 0 以上の10進 | drive 1 の面。省略時 0 |
| `system` | × | `V1S`/`V1H`/`V2`/`N`（大小無視） | 起動モード。省略時は現在設定を維持 |
| `clock` | × | `4`/`4MHz`/`8`/`8MHz`（大小無視） | CPU クロック。省略時は現在設定を維持 |

- host は `boot` 固定（将来の拡張余地。未知 host はエラー）。
- **path は必ず percent-encoding される**。PC-88 ゲームは**日本語ファイル名・
  スペース混じりが常態**なので、両側とも文字列連結禁止（§4.1 参照）。
- `disk1` 無し = drive 1 は eject。
- `disk0` 無し = エラー（何も差し替えない）。
- xm8 の `8H`/`8MHzH`（8MHz-H）は Bubilator88 に対応概念が無ければ**未対応**として
  `clock` から除外（`BootMode`/`clock8MHz` は 4/8 の二値。実装時に 8H の要否を確認、
  不要なら README に制限として明記）。

例:
```
bubilator88://boot?disk0=%2FVolumes%2FCrucialX6%2Froms%2FPC88%2FTEST%2F%E3%82%A4%E3%83%BC%E3%82%B9.d88&system=V1H&clock=4
bubilator88://boot?disk0=/x/sys.d88&bank0=0&disk1=/x/data.d88&bank1=2&system=V2
```

---

## 3. Bubilator88 側 実装

### 3.1 Info.plist に URL スキーム登録（新規）

`Bubilator88/Info.plist` に `CFBundleURLTypes` を**追加**（現状は
`UTExportedTypeDeclarations` + `CFBundleDocumentTypes` のみ）:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.bubio.Bubilator88.launch</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>bubilator88</string>
    </array>
  </dict>
</array>
```

登録後、LaunchServices に認識させるため一度アプリをビルド＆起動（or
`lsregister -f Bubilator88.app`）。

### 3.2 `.onOpenURL` の分岐（`Bubilator88App.swift`）

既存の `.onOpenURL` に URL スキーム分岐を足す。スキーム URL は
`pathExtension` が空なので `scheme` で判定:

```swift
.onOpenURL { url in
    if url.scheme?.lowercased() == "bubilator88" {
        viewModel.requestLaunch(url: url)          // ← 新規
    } else if url.pathExtension.lowercased() == "b88script" {
        viewModel.requestScriptPlayback(url: url)   // 既存
    }
}
```

> 確認事項: カスタム**スキーム**が SwiftUI `.onOpenURL` に届くこと。既存経路は
> ドキュメント**タイプ**(kAEOpenDocuments)、スキームは kAEGetURL。どちらも
> `.onOpenURL` に上がる想定だが、実機で裏取りする。万一届かない場合は
> `AppDelegate` に `application(_:open:)` を足さず、
> `NSAppleEventManager` の `kAEGetURL` ハンドラを `applicationWillFinishLaunching`
> で登録する（`docs/KNOWN_PITFALLS` の doc-open teardown 教訓に従い、
> `application(_:open:)` は復活させない）。

### 3.3 コールド起動 deferral（`pendingScriptURL` と同型・新規）

`.b88script` と同じく、コールド起動では `.onOpenURL` が ROM ロード/描画ループ
起動より先に来る。**script 用の `pendingScriptURL` は流用せず**、専用の
`pendingLaunchURL` を新設（EmulatorViewModel.swift、`@ObservationIgnored`）。

```swift
// EmulatorViewModel+Launch.swift（新規ファイル）
func requestLaunch(url: URL) {
    if isRunning && metalView != nil {
        performLaunch(url: url)
    } else {
        pendingLaunchURL = url
    }
}

func consumePendingLaunch() {
    guard let url = pendingLaunchURL else { return }
    pendingLaunchURL = nil
    performLaunch(url: url)
}
```

`ContentView.onAppear`（現状 `consumePendingScript()` を呼ぶ箇所）で
`consumePendingLaunch()` も呼ぶ。

### 3.4 URL パーサ（純粋関数・テスト対象）

`URLComponents` / `queryItems` で**自動デコード**して構造体に落とす。文字列連結・
手 decode 禁止（§4.1）。

```swift
struct LaunchRequest: Equatable {
    struct Disk: Equatable { let path: String; let bank: Int }
    var disk0: Disk          // 必須
    var disk1: Disk?         // 省略時 nil = drive1 eject
    var system: EmulatorViewModel.BootMode?   // 省略時 nil = 現状維持
    var clock8MHz: Bool?                       // 省略時 nil = 現状維持
}

enum LaunchParseError: Error, Equatable {
    case notBubilatorScheme, badHost, missingDisk0
    case badBank(String), badSystem(String), badClock(String)
}

// static func parse(_ url: URL) throws -> LaunchRequest
```

パース規則:
- `scheme != "bubilator88"` → `notBubilatorScheme`
- `host != "boot"`（大小無視）→ `badHost`
- `disk0` 空/欠落 → `missingDisk0`
- `bankN`: 空なら 0、非数値/負なら `badBank`
- `system`: `V1S/V1H/V2/N`（大小無視）→ `BootMode`。それ以外 `badSystem`
  - マッピング: `V2→.n88v2` `V1H→.n88v1h` `V1S→.n88v1s` `N→.n`
- `clock`: `4`/`4MHz`→false、`8`/`8MHz`→true（大小無視）。それ以外 `badClock`

### 3.5 検証 → 差し替えの実行（`performLaunch`）

**xm8 の「全検証してから mount」を守る**。検証で1つでも落ちたら**現在の
ドライブ/機種状態を一切触らずに** alert を出して return。

```
func performLaunch(url: URL):
  1. req = try LaunchRequest.parse(url)   // 失敗 → showAlert, return
  2. if !romLoaded { loadROMs() }
  3. 検証フェーズ（machine を触らない）:
       for each disk in [disk0, disk1?]:
         - Data(contentsOf:) 読める？（.m3u は別扱い or 今回は D88 のみ検証）
         - D88Disk.parseAll → images
         - req.bank < images.count か？（丸め込み禁止）
       いずれか失敗 → showAlert（どのファイル/bank が原因か明示）, return
  4. 適用フェーズ（ここから状態変更。playScript / performReset を参考に）:
       - cancelScriptPlayback(); cancelScriptRecording(); stop(); cancelPasteQueue()
       - system 指定あり → _bootModeStorage と Settings.dipSw1/dipSw2Base を設定
         （setter 経由だと即 reset するので、adoptScriptSetup と同様に直接代入）
       - clock 指定あり → Settings.clock8MHz = req.clock8MHz
       - drive 0/1 を明示 imageIndex で mount（§3.6、picker を出さない）
         disk1 無し → ejectDisk(drive: 1)
       - 単発 cold reset: performReset 相当（preserveRAM: false）で disk0 から IPL 起動
       - start()（未 running なら）
       - showToast("起動: <disk0 名>")
```

> 適用順の注意: `bootMode`/`clock8MHz` の **setter を使うと 1 回ごとに
> `applyBootMode()→performReset` が走る**。mount 前後で多重 reset して
> 状態が壊れるので、**backing storage（`_bootModeStorage` / `Settings`）へ直接代入
> → 最後に一度だけ cold reset**、という順序にする（`adoptScriptSetup` が同じ
> 「setter を避けて直接同期」パターン）。

### 3.6 明示 imageIndex mount（picker 回避・新規入口）

`mountDisk(url:target:)` は**多面 D88 かつ index 無指定だと picker シートを出す**。
URL は明示 bank を持つので picker を回さない入口が要る。既存 private
`mountDiskImage(_:allImages:imageIndex:url:drive:)`（EmulatorViewModel+Disk.swift:527）
が中身そのもの。これを呼ぶ internal 入口を追加:

```swift
func mountDisk(url: URL, drive: Int, imageIndex: Int) {
    let data = ... // Data(contentsOf: url)
    let disks = D88Disk.parseAll(data: Array(data))
    let idx = min(max(0, imageIndex), disks.count - 1)  // 検証済み前提だが安全側
    mountDiskImage(disks[idx], allImages: disks, imageIndex: idx, url: url, drive: drive)
    Settings.shared.addRecentFile(url: url)
}
```

§3.5 の検証フェーズと読み込みが二重になるので、**検証フェーズで parseAll 済みの
`[D88Disk]` を持ち回って mount 側へ渡す**設計にして二度読みを避けてもよい
（実装者判断。ファイルは通常小さいので二度読みでも可）。

`.m3u` を許可するなら `mountM3U` 経路を通す必要がある。**初版は D88 のみ対応、
m3u は次段**とする（README に明記）。

---

## 4. 実装上の落とし穴（必読）

### 4.1 【最重要】パスの percent-encoding

対象は PC-88 ゲーム → **ファイル名はほぼ日本語・スペース混じり**。

- FlipDisk 側: Dart `Uri(scheme:'bubilator88', host:'boot', queryParameters:{...})`
  で組む（**自動エンコード**）。文字列連結でクエリを作らない。
- Bubilator88 側: `URLComponents.queryItems` の `.value` を使う（**自動デコード**）。
  手 `removingPercentEncoding` を重ねない（二重デコード事故）。
- 回帰テスト必須: `/Volumes/CrucialX6/roms/PC88/TEST/イース II.d88` のような
  **日本語＋スペース**パスで round-trip 1本。

### 4.2 非サンドボックス（security-scoped bookmark 不要）

`EmulatorViewModel+Script.swift` 冒頭コメントのとおり entitlements 空 = 非
サンドボックス。**デコード後の絶対パスを直読みでき、bookmark 不要**。
`startAccessingSecurityScopedResource` は URL 起動経路では不要（既存 mount 経路が
呼んでいても no-op で害はない）。

### 4.3 `application(_:open:)` を復活させない

`docs/KNOWN_PITFALLS` / memory `project_doc_open_window_teardown` の教訓:
`application(_:open:)` 実装はウィンドウ teardown / コールド起動黒画面 / AI FPS
低下を招いた。**`.onOpenURL` 一本化を維持**する。スキームが `.onOpenURL` に
届かない場合のみ、§3.2 の `NSAppleEventManager` kAEGetURL ハンドラで補う。

### 4.4 多重 reset を避ける（§3.5 の適用順）

setter 経由の boot mode / clock 変更は都度 reset を誘発する。直接代入 →
最後に単発 cold reset。

---

## 5. FlipDisk 側 実装（`lib/services/launcher.dart`）

現状は 2 分岐（`.app`→`open --args` / それ以外→直 exec）。**URL スキーム用の
第3経路を足す**。generic な argument-template + 手エンコードは §4.1 のとおり
壊れるので、**Bubilator88 専用の URL ビルダ**で組む。

判定方法（どちらか実装者判断）:
- emulator 設定に「起動方式 = urlScheme」フラグ + `urlScheme`(=`bubilator88`) を持たせる、または
- executable が Bubilator88.app（bundle id `com.bubio.Bubilator88`）なら URL 経路。

URL 構築（Dart、**必ず `Uri` で組む**）:

```dart
final uri = Uri(
  scheme: 'bubilator88',
  host: 'boot',
  queryParameters: {
    'disk0': disk0AbsolutePath,          // 生パス。Uri が自動エンコード
    if (bank0 != 0) 'bank0': '$bank0',
    if (disk1 != null) 'disk1': disk1AbsolutePath,
    if (disk1 != null && bank1 != 0) 'bank1': '$bank1',
    if (system != null) 'system': system,   // 'V1H' 等
    if (clock != null) 'clock': clock,       // '4' / '8'
  },
);
await Process.start('open', [uri.toString()]);
// もしくは配信先を明示: ['-a', executablePath, uri.toString()]
```

- FlipDisk の per-game パラメータ（Phase 9/11 の system/clock/bank）を上記
  query に写像する。
- `open <url>` は fire-and-forget（既存の launcher と同じく監視しない）。
- 起動中インスタンスがあれば LaunchServices が既存プロセスへ URL を配送
  → 差し替え。無ければコールド起動 → deferral 経路。

---

## 6. テスト計画

- **単体（EmulatorCore or App テスト）**: `LaunchRequest.parse` の網羅
  - 正常: disk0 のみ / disk0+bank / 2枚 / system 各値 / clock 各値
  - 異常: scheme 違い / host 違い / disk0 欠落 / bank 非数値・負 / system 不正 / clock 不正
  - **日本語＋スペースパスの round-trip**（§4.1）
  - system 大小混在（`v1h`）を受理
- **統合（手動 or BootTester 相当）**:
  - コールド起動: `open 'bubilator88://boot?disk0=…'` → ゲーム起動
  - ウォーム差し替え: アプリ起動中に別 URL → 同一ウィンドウでディスク差し替え・再起動
  - 検証失敗（存在しない bank）→ alert が出て**現状維持**（前のゲームが生きたまま）
- **回帰**: `EmulatorCore/Sources` は変更しない見込み（App 層のみ）だが、
  `mountDiskImage` 周辺に触れる場合は `/regression`（scripts/regression_compare.py）を
  コミット前に実行（CLAUDE.md 規約）。

---

## 7. 段階実装（各段でビルド＆テストが通ること）

1. **Phase 1 — パーサ**: `LaunchRequest` + `parse` + 単体テスト（machine 非依存）。
2. **Phase 2 — Info.plist + onOpenURL 配線**: スキーム登録、`requestLaunch`/
   `pendingLaunchURL`/`consumePendingLaunch`、`.onOpenURL` 分岐。スキームが
   `.onOpenURL` に届くことを実機確認（§3.2）。
3. **Phase 3 — 明示 imageIndex mount 入口**（§3.6）。
4. **Phase 4 — performLaunch**: 検証→適用→単発 cold reset→start（§3.5）。
   ウォーム差し替え・コールド起動の両方を手動確認。
5. **Phase 5 — FlipDisk 第3経路**（§5）。実ランチャーから 2〜3 本のゲームで確認。
6. **Phase 6 — README/docs 追記**: URL フォーマット、対応/未対応（m3u・8H）を明記。

---

## 8. スコープ外（初版）

- ターミナルからの literal argv 起動（`bubilator88 game.d88`）
- `.d88` の Finder ダブルクリック/ドラッグ起動（`CFBundleDocumentTypes` 追加）
- `.m3u` の URL 経由 mount（Phase 追加で対応可）
- xm8 の `8H`/`8MHzH`（対応概念があれば拡張）
- system/clock のセッション限定 restore（永続化で確定）
