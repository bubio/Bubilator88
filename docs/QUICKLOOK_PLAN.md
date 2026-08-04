# セーブステート QuickLook 対応 実装計画

`.b88s` を単体で自己完結させ、Finder のサムネイル表示とスペースキープレビューを
Quick Look 拡張で提供するための設計メモ。

**進捗: Phase 1・2・3 実装済み、サイドカー書き込みも停止済み (2026-08-04)。
本計画の作業項目は完了。**

## 1. 背景と現状

セーブステートは現在 **1 セーブにつき 3 ファイル** を書いている
(`EmulatorViewModel.performSave`, `EmulatorViewModel.swift:1183` 付近):

| ファイル | 内容 | 書き込み箇所 |
|----------|------|--------------|
| `slot_N.b88s` | マシン状態本体 | `machine.createSaveState()` (thumbnail 引数なし) |
| `slot_N.meta.json` | `SaveMeta` (bootMode, ドライブ名, sourceURL, archiveEntry 等) | `EmulatorViewModel.swift:1206` |
| `slot_N.thumb.png` | 320×200 サムネイル | `EmulatorViewModel.swift:1209` |

サイドカー PNG は **Finder で見たときに中身が分かるように** という意図で最初から
存在する。この目的自体は妥当だが、Quick Look 拡張を用意すれば `.b88s` 単体でも
Finder のアイコンにサムネイルが出るため、上位互換で置き換えられる。単体で完結すれば
ユーザが `.b88s` をコピー・共有したときにサムネイルとメタが失われない。

### フォーマット側の下地は既にある

- `SaveStateFile.build(sections:thumbnail:)` は **THMB セクションの書き出しに対応済み**
  (`SaveState.swift:226`)。ヘッダ 0x34/0x38 にサムネイルのオフセットとサイズも書かれる
- `META` セクションも存在するが、EmulatorCore が書くのは
  `{"disk0":…,"disk1":…,"clock8MHz":…}` の最小 JSON のみ (`SaveStateSerialize.swift:725`)。
  アプリ層の `SaveMeta` はそれより情報量が多く、サイドカー JSON にしか存在しない
- 現行フォーマットバージョンは **3** (`SaveState.swift:184`)

> 注意: `docs/SAVE_STATE.md` はバージョン 2 時点で止まっており、**内容が実装と乖離している**。
> 判明している分だけでも:
>
> - 変更履歴表が v2 までしかない (実装は v3)
> - `SaveState.swift:311` のコメントによれば v2 は「もう存在しない chase-heuristic
>   フィールド」を持っていた → §2 の MAIN レイアウト記述自体が古い
> - `createSaveState` が書く `CMT ` セクション (カセット + I8251,
>   `SaveStateSerialize.swift:717`) が §1 のセクション一覧に無い
>
> v3 の履歴行を書くには実際の `writeSaveState` の順序と §2 を突き合わせる必要がある。
> 一行追記で済む作業ではない。

`.b88s` の UTType は **未宣言**。`Bubilator88/Info.plist:11` の
`UTExportedTypeDeclarations` にあるのは `b88script` だけ。

## 2. 設計方針

### 2.1 段階

| Phase | 内容 | 単体で価値があるか |
|-------|------|--------------------|
| 1 | `.b88s` の自己完結化 (THMB + アプリメタをファイル内に格納) | ○ (単体コピーで情報が保たれる) |
| 2 | UTType 宣言 + Quick Look Thumbnail Extension | ○ (Finder アイコンがサムネイルになる) |
| 3 | Quick Look Preview Extension (スペースキー) | ○ |

Phase 1 だけ先に入れてもサイドカーは残せるので、リリース単位を分けられる。

### 2.2 アプリメタの格納先 — 新セクション `AMTA`

EmulatorCore はアプリ層に依存できない (レイヤ規則) ので、`SaveMeta` を core の
`META` に混ぜることはしない。代わりに **アプリ層が自前のセクションを足せる口** を
core に開ける:

```swift
public func createSaveState(thumbnail: [UInt8]? = nil,
                            extraSections: [(tag: UInt32, data: [UInt8])] = []) -> [UInt8]
```

`extraSections` は `sections` の末尾に連結してから `SaveStateFile.build` へ渡すだけ。
core はタグの意味を知らないので依存は発生しない。アプリ側は
`SaveStateFile.fourCC("AMTA")` に `JSONEncoder().encode(meta)` を入れて渡す。

### 2.3 フォーマットバージョンは上げない

`SaveStateFile.parse` はセクションテーブルを走査して **全タグを辞書に入れるだけ**で、
未知タグがあってもエラーにならない (`SaveState.swift:334`)。`loadSaveState`
(`SaveStateSerialize.swift:731`) も既知タグを辞書引きするだけで、セクション数の検証や
未知タグの拒否は行わない (確認済み)。したがって `AMTA` / `THMB` の追加は前方互換であり、`currentVersion` は 3 のまま
でよい。**古いアプリで新しいファイルを読んでもマシン状態の復元は成功する** (アプリメタと
サムネイルが無視されるだけ)。

### 2.4 サイドカーの扱い — 読みは残し、書きだけ止める

| 時期 | `.b88s` 内 | `.thumb.png` / `.meta.json` |
|------|-----------|------------------------------|
| Phase 1 | 書く | **書く** (併存。移行期間) |
| Phase 2 完了後 (現行) | 書く | 書かない。**読みフォールバックは残す** |

既存ユーザのセーブスロットには `.b88s` 内に THMB/AMTA が無いものが残るので、読み出しは
「ファイル内 → 無ければサイドカー」の順で見る。既存のサイドカーファイルを削除しては
**いけない** (セーブ系データの自動削除は禁止)。

## 3. Phase 1: `.b88s` の自己完結化 (実装済み)

実装は `SaveState.swift` (`parseSectionTable`)、`SaveStateSerialize.swift`
(`createSaveState(extraSections:)`)、`Bubilator88/ViewModel/SaveStateFileAccess.swift`
(部分読み)、`EmulatorViewModel.swift` (`loadMeta` / `loadThumbnailData` と
`performSave` / `performLoad`) に入っている。以下は設計時の記述。

### 3.1 変更点

- `Machine.createSaveState` に `extraSections` 引数を追加 (EmulatorCore)
- `performSave`: `captureThumbnail()` の PNG を `thumbnail:` に、`SaveMeta` の JSON を
  `AMTA` セクションとして渡す。サイドカー書き込みは Phase 1 では残す
- 読み出し系を「ファイル内優先 + サイドカーフォールバック」に統一

読み出し側の対象は 2 種類あり、**重要度が違う**:

| 種別 | 箇所 | フォールバック漏れの影響 |
|------|------|--------------------------|
| **復元パス** | `performLoad` が `metaPath` から `SaveMeta` を読み、ブートモード / DIP スイッチ / ドライブ名 / `reconstructDiskInfo` によるディスク再マウントを復元している (`EmulatorViewModel.swift:1246` 付近) | **大**。ディスク切替メニューの再構成やブートモード復元が黙って失われる |
| 表示のみ | `quickSaveInfo` / `quickSaveLabel` / `quickSaveThumbnail` / スロット一覧のメタ・サムネ (1423 / 1443 / 1454 / 1459 / 1464 行付近) | 小。ラベルやサムネが出ないだけ |

復元パスを最初に直し、`AMTA` があればそれを、無ければサイドカー JSON を読む形にする。

### 3.2 部分読み — core は純粋なまま保つ

スロット一覧 UI とプレビュー拡張の両方が「3MB のファイルからサムネイルだけ欲しい」
状況になる。ただし **EmulatorCore にファイル I/O を持ち込んではいけない** —
ライブラリターゲットには `FileManager` / `FileHandle` の使用が 1 箇所も無く
(あるのは `BootTester` 実行ファイルターゲットのみ)、この純粋性は Windows 移植の前提
でもある。§4.2 で拡張ターゲットに EmulatorCore をリンクできると言えるのも、これが
成り立っているからである。

そこで core にはバイト列だけを扱う関数を置き、ファイル読みは呼び出し側 (アプリ層 /
拡張ターゲット) が行う:

```swift
extension SaveStateFile {
  /// Parse just the header and section table from the leading bytes of a file.
  public static func parseSectionTable(_ bytes: [UInt8]) throws
    -> [(tag: UInt32, offset: Int, size: Int)]
}
```

呼び出し側は `FileHandle` で先頭 64 バイト → セクション数から必要な
`sectionCount * 12` バイト → 目的セクションへ `seek` して読む。全読みは発生しない。

ヘッダ 0x34/0x38 のサムネイルオフセット・サイズを使えば THMB はテーブルを読まずとも
取れるが、`AMTA` には使えないのでテーブル経由の汎用実装にする。

### 3.3 テスト

- `extraSections` で渡したタグが `parse` の戻り値に含まれること
- `AMTA` 入りのファイルを**旧来の**ロードパスに通しても復元が成功すること (前方互換)
- `parseSectionTable` が `parse` と同じタグ・オフセット・サイズを返すこと
- EmulatorCore/Sources を触るので、**コミット前に `/regression` 必須**

## 4. Phase 2: UTType 宣言 + Thumbnail Extension (実装済み)

実装の実際:

- `Bubilator88QuickLook/` — `ThumbnailProvider.swift` (`QLThumbnailProvider`)、
  `Info.plist` (`com.apple.quicklook.thumbnail`)、サンドボックス entitlements
- **共有ソースは `Shared/` に置いた。** `SaveStateFileAccess.swift` はアプリと拡張の
  両方でコンパイルする必要があるが、Xcode 16 の同期グループ
  (`PBXFileSystemSynchronizedRootGroup`) は「フォルダ丸ごと 1 ターゲット」が基本で、
  `Bubilator88/` 配下の 1 ファイルだけを別ターゲットにも入れるのは素直に書けない。
  独立した `Shared/` を作り、両ターゲットの `fileSystemSynchronizedGroups` に載せる
  のが最も素直だった。この構成のため同ファイルはアプリ状態に依存させないこと
- `project.pbxproj` はターゲット定義・埋め込みフェーズ (`dstSubfolderSpec = 13`)・
  EmulatorCore の `XCSwiftPackageProductDependency` を手で追記した

### 動作確認 (2026-08-04)

`UTType(filenameExtension: "b88s")` が `com.bubio.bubilator88.save-state` を返し、
`QLThumbnailGenerator` が `.thumbnail` 表現として 512×320 の実画面
(スタークルーザーのセーブ) を生成することを確認済み。

> `qlmanage -t` はこの環境でハングして使えなかった。検証には
> `QLThumbnailGenerator.generateBestRepresentation` を使うほうが速い。
> `mdls` の `kMDItemContentType` は登録直後は古い dynamic UTI を返すので判定に使わない
> (`UTType(filenameExtension:)` か `URL.resourceValues(forKeys: [.contentTypeKey])` を見る)。

以下は設計時の記述。

## 4'. Phase 2 設計メモ

### 4.1 UTType

`Bubilator88/Info.plist` の `UTExportedTypeDeclarations` に追加:

| キー | 値 |
|------|-----|
| `UTTypeIdentifier` | `com.bubio.bubilator88.save-state` |
| `UTTypeDescription` | `Bubilator88 Save State` |
| `UTTypeConformsTo` | `public.data` |
| `public.filename-extension` | `b88s` |

`CFBundleDocumentTypes` への追加 (= ダブルクリックで `.b88s` を開けるようにする) は
**この計画のスコープ外**。ステートロードは実行中のエミュレータ状態を差し替える操作で、
起動フローとの整合を別途詰める必要があるため、別タスクとする。

### 4.2 拡張ターゲット

- Xcode に **Quick Look Thumbnail Extension** ターゲットを追加
- `QLThumbnailProvider` は §3.2 の部分読みで THMB の PNG を取り出し、
  そのまま描画するだけ。THMB が無い旧ファイルは汎用アイコンにフォールバック
- EmulatorCore はプラットフォーム API 非依存の純 Swift パッケージなので、
  拡張ターゲットからそのままリンクしてよい。パーサを複製しない

### 4.3 注意点

- **拡張は必ずサンドボックス内で動く**。アプリ本体の entitlements が空 (非サンドボックス)
  でも拡張側には `com.apple.security.app-sandbox` が要る。読み取り対象は
  リクエストで渡される URL のみなので、追加の権限は不要
- Finder のサムネイルはキャッシュされる。動作確認時は `qlmanage -r cache` が必要
- 拡張のコード署名がアプリ本体と揃っていないと Finder に認識されない

## 5. Phase 3: Preview Extension (実装済み)

`Bubilator88QuickLookPreview/` — `QLPreviewProvider` による data-based preview。
HTML を返し、スクリーンショットは `QLPreviewReplyAttachment` として `cid:screen` で
参照する。表示は 640×400 の画面 (`image-rendering: pixelated` で 2 倍表示) +
ディスク名 / ブートモード / CPU クロック / 保存日時。配色は `Canvas` /
`CanvasText` システムカラーで light・dark 両対応。

ラベル (ディスク / ブートモード / CPU クロック / 保存日時、およびスクリーンショット
なしのプレースホルダ) は `Bubilator88QuickLookPreview/Resources/Localizable.xcstrings`
で日本語化してある。**拡張は独立したバンドルなのでアプリの String Catalog は参照
できず、拡張ターゲット自身に置く必要がある** (`String(localized:)` が見るのは
`Bundle.main` = appex バンドル)。保存日時は `DateFormatter.localizedString` なので
ロケールに従う。

**なぜターゲットが 2 つなのか:** 1 つの appex が持てる `NSExtensionPointIdentifier`
は 1 つだけで、サムネイル (`com.apple.quicklook.thumbnail`) とプレビュー
(`com.apple.quicklook.preview`) は別の extension point。したがってサムネイル用と
プレビュー用で appex を分ける必要がある。両方とも `Shared/` と EmulatorCore を
共有し、アプリの Embed Foundation Extensions フェーズに同居する。

### 制約: 旧セーブのプレビューは情報が減る

拡張はサンドボックス内で動き、Quick Look から渡された **その URL しか読めない**。
`.b88s` の隣にある `.meta.json` / `.thumb.png` サイドカーは読めないので、
`THMB`/`AMTA` を持たない旧セーブのプレビューは以下だけになる:

| 項目 | 旧セーブでの可否 | 出所 |
|------|-----------------|------|
| スクリーンショット | ✗ (プレースホルダ表示) | `THMB` |
| ブートモード | ✗ | `AMTA` のみ |
| ディスク名 | ○ | `META` (コアが以前から書いている) |
| CPU クロック | ○ | `META` |
| 保存日時 | ○ | ヘッダ 0x08 |

アプリ内のスロット一覧はサイドカーにフォールバックするので従来どおり全部出る。
差が出るのは Finder のプレビューだけ。

### 検証 (2026-08-04)

`pluginkit -m -p com.apple.quicklook.preview` で登録を確認。生成される HTML を
WKWebView でレンダリングして目視確認済み (サムネイルあり / ディスク名あり /
旧セーブの 3 パターン)。

> 初版はプレースホルダが黒背景に薄い黒文字で不可視だった。`.missing` は
> `.screen` の黒塗りを上書きする必要がある。

### 落とし穴: `QLIsDataBasedPreview` は必須

`NSExtensionAttributes` に **`QLIsDataBasedPreview = true` が無いと、`QLPreviewProvider`
であっても QuickLook はビューコントローラ型の拡張として起動しようとして落ちる**。
症状は Finder でくるくる回り続け、サムネイルも出なくなる (サムネイルが `THMB` を
持たないファイルではプレビュー経由で生成されるため、巻き添えになる)。

ログにはこう出る:

```
E  Bubilator88QuickLookPreview: *** Assertion failure in <private>, QLPreviewExtensionViewController.m:139
```

Xcode の "Quick Look Preview Extension" テンプレートは**ビュー型が既定** で
(`QLIsDataBasedPreview` は `false`、principal class は `PreviewViewController`)、
data-based にするには手で切り替える必要がある。Apple 自身の data-based 拡張
(`Icon Composer QuickLook Preview.appex`) の Info.plist が参考になる。

デバッグ方法: `log show --last 5m --predicate 'process CONTAINS "Bubilator88QuickLookPreview"'`。
`qlmanage -p` はウィンドウを開いて返ってこないが、**拡張自体は起動するのでログは取れる**。
また Debug と Release の両方が Launch Services に登録されていると、片方だけ直しても
古い方が使われることがある (両方ビルドし直すこと)。

## 5'. Phase 3 設計メモ

`QLPreviewProvider` でスペースキープレビューを実装する。表示内容:

- THMB のサムネイル (拡大表示)
- `AMTA` から: ブートモード、ドライブ 0/1 のディスク名
- ヘッダ 0x08 のタイムスタンプから保存日時
- `META` から: CPU クロック (4/8MHz)

出力は HTML かレンダリング済み画像。ローカライズは既存の仕組みに合わせる。

## 6. 作業順序

1. `createSaveState(extraSections:)` + `readSection` を EmulatorCore に追加、テスト
2. `performSave` を THMB + `AMTA` 書き込みに変更 (サイドカーは併存)
3. 読み出し系をファイル内優先 + フォールバックに統一
4. `/regression` → ここまでで Phase 1 として ship 可能
5. UTType 宣言 + Thumbnail Extension ターゲット追加
6. `qlmanage -r cache` で Finder 表示を確認 → サイドカー書き込みを停止 (実装済み。
   `performSave` は `.b88s` 一本のみ書く。`metaPath` / `thumbnailPath` は
   読みフォールバック専用として残置)
7. `docs/SAVE_STATE.md` の実装との突き合わせ (§1 の注記参照)。`AMTA` セクション追加に
   加えて、`CMT ` の追記・MAIN レイアウトの v3 反映・変更履歴の v2→v3 記入が必要。
   併せて `docs/PERSISTENCE.md` のセーブステート項目を更新
8. Preview Extension (Phase 3)

## 7. スコープ外

- **macOS の Versions / `NSFileVersion` によるセーブ履歴** — 検討済みで不採用
  (2026-08-04)。OS のバージョンストアは経過時間とディスク空き容量で自動的に間引かれ、
  セーブ系データを自動削除しないという方針と両立しない
- `.b88s` のダブルクリック起動 (4.1 参照)
- 既存サイドカーファイルの削除・移行スクリプト — 残置する
