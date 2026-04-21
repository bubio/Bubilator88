# Apple Help Book — 実装ノートとトラブルシューティング

macOS の Apple Help Book (Help Viewer) を Bubilator88 に組み込む際に得た知見。
開発中に遭遇した落とし穴と、複数の外部リソースから収集した情報を統合している。

### 参考資料

- [Apple Help Programming Guide (Archive)](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/ProvidingUserAssitAppleHelp/authoring_help/authoring_help_book.html) — 公式ドキュメント（2013年、一部誤り有り）
- [Mario Guzman: Authoring macOS Help Books in 2020](https://marioaguzman.wordpress.com/2020/09/12/auth/) — 最も実践的なステップバイステップガイド（2025年更新）
- [Alastair Houghton: Apple Help in 2015](https://alastairs-place.net/blog/2015/01/14/apple-help-in-2015/) — 公式ドキュメントの誤りを指摘した重要記事
- [Chuck Houpt: jekyll-apple-help](https://github.com/chuckhoupt/jekyll-apple-help) — Jekyll ベースの Help Book テンプレート
- [LocationSimulator-Help](https://github.com/Schlaubischlump/LocationSimulator-Help) — jekyll-apple-help の実プロジェクト例
- [Howard Oakley: How Help Works](https://eclecticlight.co/2023/05/11/how-help-works-and-how-it-doesnt/) — helpd の内部動作とキャッシュ解析

---

## 1. ファイル構成

```
Bubilator88/
├── Bubilator88/
│   ├── Info.plist                    ← アプリ側: CFBundleHelpBookName/Folder
│   └── Bubilator88.help/            ← Help Book バンドル (.help)
│       └── Contents/
│           ├── Info.plist            ← Help Book メタデータ
│           └── Resources/
│               ├── shrd/            ← 共有リソース (CSS, 画像)
│               │   ├── helpstyle.css
│               │   └── screenshot-*.png
│               ├── en.lproj/        ← 英語
│               │   ├── _access.html ← XHTML 1.1 エントリポイント (必須)
│               │   ├── index.html   ← 実際のトップページ (HTML5可)
│               │   ├── search.cshelpindex
│               │   └── pgs/*.html
│               └── ja.lproj/        ← 日本語
│                   ├── _access.html
│                   ├── index.html
│                   ├── search.cshelpindex
│                   └── pgs/*.html
```

### Xcode プロジェクトへの追加

`.help` フォルダは Xcode プロジェクト内のアプリターゲットに含める。PBXFileSystemSynchronizedRootGroup を使っている場合、`Bubilator88/` 内に置けば自動認識される。

---

## 2. Info.plist 設定

### アプリ側 Info.plist

```xml
<key>CFBundleHelpBookFolder</key>
<string>Bubilator88.help</string>
<key>CFBundleHelpBookName</key>
<string>Bubilator88 Help</string>
```

**注意**: `CFBundleHelpBookName` は Help Book の `HPDBookTitle` と**揃えておくのが安全**。Alastair Houghton 氏は一致必須と報告しているが、出荷アプリ (Mactracker 等) で一致していない例もある。不一致時に汎用ヘルプが開く場合はここを確認すること。

### Help Book 側 Info.plist — 全キー一覧

```xml
<key>CFBundleDevelopmentRegion</key>
<string>en</string>
<key>CFBundleIdentifier</key>
<string>com.bubio.Bubilator88.help</string>
<key>CFBundleInfoDictionaryVersion</key>
<string>6.0</string>
<key>CFBundleName</key>
<string>Bubilator88 Help</string>
<key>CFBundlePackageType</key>
<string>BNDL</string>
<key>CFBundleShortVersionString</key>
<string>1.0</string>
<key>CFBundleSignature</key>
<string>hbwr</string>
<key>CFBundleVersion</key>
<string>1</string>
<key>HPDBookAccessPath</key>
<string>_access.html</string>
<key>HPDBookIndexPath</key>
<string>search.cshelpindex</string>
<key>HPDBookTitle</key>
<string>Bubilator88 Help</string>
<key>HPDBookType</key>
<string>3</string>
<key>HPDBookKBProduct</key>
<string>Bubilator88</string>
```

| キー | 説明 |
|------|------|
| `CFBundleSignature` | 常に `hbwr` (Help Book Writer) |
| `CFBundlePackageType` | 常に `BNDL` |
| `HPDBookType` | `3` = ローカルヘルプ |
| `HPDBookAccessPath` | XHTML エントリポイント（各 lproj 内の相対パス） |
| `HPDBookIndexPath` | hiutil で生成した検索インデックスのファイル名 |
| `HPDBookTitle` | 表示名。**アプリの CFBundleHelpBookName と一致必須** |
| `HPDBookKBProduct` | Apple KB タグコード（検索絞り込み用） |
| `HPDBookRemoteURL` | リモートコンテンツの URL (Type 1/2 用、ローカル専用なら不要) |
| `HPDBookIconPath` | ヘルプブックアイコン（Resources からの相対パス） |

### 公式ドキュメントの誤り

- `CFBundleDevelopmentRegion`: Apple のドキュメントでは `en_us`（アンダースコア）だが、**正しくはハイフン `en-us`**。Apple 自身のツールはハイフン形式を生成する。

---

## 3. アクセスページ (HPDBookAccessPath)

`HPDBookAccessPath` で指定するエントリポイントHTML。Apple のアーカイブ文書は XHTML 形式で説明しているが、ファイル名は `_access.html` に固定ではなく、現物では別名も使われている。

**XHTML 1.1 形式にしておくのが安全**。HTML5 ではサイレントに失敗するケースが報告されている（Alastair Houghton 氏）。実際の index.html は HTML5 で問題ないため、XHTML シムからリダイレクトする方式が実用的。

```html
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN"
  "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
  <head>
    <title>Bubilator88 Help</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <meta name="robots" content="noindex" />
    <meta http-equiv="refresh" content="0;url=index.html" />
  </head>
  <body></body>
</html>
```

**注意点**:
- `<meta http-equiv="refresh">` で index.html (HTML5可) にリダイレクト
- `robots` は `noindex` (このファイル自体は検索結果に出さない)
- 各 lproj に同じ構造の _access.html が必要
- `<meta name="AppleTitle">` は Alastair 氏によると不要（レガシー）だが、あっても害はない

---

## 4. 検索インデックス

### hiutil v2 (macOS 13+) — 2種類のインデックス

macOS Ventura 以降の `hiutil` は 2つの形式をサポートする：

| 形式 | フラグ | 拡張子 | 用途 |
|------|--------|--------|------|
| CoreSpotlight | `-I corespotlight` | `.cshelpindex` | Help Viewer 検索（**必須**） |
| LSM | `-I lsm` | `.helpindex` | 後方互換（推奨） |

**両方生成するのがベストプラクティス**（Mario Guzman 推奨）：

```bash
cd Bubilator88/Bubilator88.help/Contents/Resources/en.lproj
hiutil -I corespotlight -Caf search.cshelpindex .
hiutil -I lsm -Caf search.helpindex .
```

Info.plist には両方指定可能：
```xml
<key>HPDBookCSIndexPath</key>
<string>search.cshelpindex</string>
<key>HPDBookIndexPath</key>
<string>search.helpindex</string>
```

### 致命的エラー: フラグなし hiutil

```bash
# NG — NSKeyedArchiver (typedstream) 形式が生成される。Help Viewer で読めない。
hiutil -Caf search.helpindex .
# → "There was a problem unarchiving the index file." エラー

# OK
hiutil -I corespotlight -Caf search.cshelpindex .
```

### 検証コマンド (hiutil 2.0)

```bash
# アンカー一覧
hiutil -I corespotlight -Af search.cshelpindex

# インデックス内容のダンプ
hiutil -I corespotlight -Ff search.cshelpindex

# バリデーション
hiutil -I corespotlight -Tvf search.cshelpindex
```

> **注意**: hiutil 2.0 では `--search` や `--list-anchors` は使えない。`-A` (anchors), `-F` (file list), `-T` (validate) を使う。
> また `man hiutil` には「ローカル help book のインデックスはシステムが自動生成する」とも記されており、`.cshelpindex` は有益だが絶対条件とは限らない。

### アンカーの仕組み

HTML の `<a name="anchor-name"></a>` がアンカーになる。`NSHelpManager.shared.openHelpAnchor("anchor-name", ...)` でそのページに直接ジャンプできる。

### 完全一致検索 (Exact Match)

各 lproj に `.plist` ファイルを置き、検索語→アンカー ID のマッピングを定義可能。一致した場合 100% 関連度でトップ表示される。

---

## 5. SwiftUI からのヘルプ呼び出し

```swift
CommandGroup(replacing: .help) {
    Button("Bubilator88 Help") {
        if let bookName = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleHelpBookName") as? String {
            NSHelpManager.shared.openHelpAnchor(
                "bubilator88-help", inBook: bookName)
        }
    }
    .keyboardShortcut("?", modifiers: .command)
}
```

### NSAlert との連携

```swift
let alert = NSAlert()
alert.showsHelp = true
alert.helpAnchor = NSHelpManager.AnchorName("my-anchor")
```

### ヘルプブックの手動登録

```swift
// helpd が自動検出しない場合の代替手段
NSHelpManager.shared.registerBooks(in: Bundle.main)
```

---

## 6. ローカライゼーション

### lproj 構成

- `en.lproj/` と `ja.lproj/` にそれぞれ同じファイル構成を用意
- 共有リソース (CSS, 画像) は `shrd/` にまとめる
- 各 lproj に `_access.html`, `index.html`, `search.cshelpindex` が必要
- CSS パスは `../shrd/helpstyle.css`、画像も同様に `../shrd/` からの相対パス

### 翻訳してはいけないもの

- ファイル名
- アンカー名 (`<a name="...">`)
- `<meta name="robots">` の値
- Info.plist のキー名

### HPDBookTitle のローカライゼーション

Info.plist の `HPDBookTitle` に Bundle ID を書き、`InfoPlist.strings` で言語ごとにオーバーライドする方法もある：

```
/* InfoPlist.strings (ja.lproj) */
HPDBookTitle = "Bubilator88 ヘルプ";
```

### 画像の共有

スクリーンショットなど言語共通の画像は `shrd/` に置き、各 HTML から相対パスで参照：

```html
<img src="../shrd/screenshot-main.png" alt="...">
```

---

## 7. ナビゲーション (目次)

### Apple 純正ヘルプとの違い

Mac ユーザガイド等のスクリーンショットに見えるサイドバーは、Help Viewer が提供する**ネイティブ部品**であり、サードパーティの .help バンドルでは利用できない（2026年4月時点）。`window.HelpViewer` は非公開 API で、macOS バージョンごとにプロパティや動作が変化するため依存は避けるべき。

サードパーティアプリで再現できるのは「似た体験」であって「同じネイティブ部品」ではない。

### 現実的なアプローチ

1. **ページ内ナビゲーション（本体）**: 各ページにトピック一覧へのリンクと「ヘルプに戻る」リンクを配置
2. **自前サイドバー（拡張）**: HTML/CSS/JS で左サイドバーを実装し、ページ内ボタンでトグル
3. **検索と起動**: Help Book の公開仕様 (`NSHelpManager`, `hiutil`) に乗る

### 自前サイドバーの実装

各 HTML ページに `<nav>` と `<div class="help-content">` を配置し、JS でトグルする：

```html
<body>
    <nav role="navigation" aria-hidden="true">
        <h3>目次</h3>
        <ul>
            <li><a href="...">トピック名</a></li>
        </ul>
    </nav>

    <div class="help-content">
        <!-- ページの本文 -->
        <p><a href="../index.html">ヘルプに戻る</a></p>
    </div>

    <script src="../../shrd/helptoc.js"></script>
</body>
```

- `<nav>` はページ内トグルボタンで表示/非表示を切り替える
- `window.HelpViewer` が存在する場合でも JS コールバックに依存しない
- 本文内の相互リンク（「ヘルプに戻る」等）が本体のナビゲーション手段

---

## 8. Help Viewer の概要

Help Book を表示するシステムは macOS バージョンごとに内部構成が変化している（HelpViewer.app → Tips.app 等）。内部パスやプロセス名に依存せず、公開 API (`NSHelpManager`, `CFBundleHelpBookName` 等) のみに依存すること。

ヘルプ表示に関わる要素：
- **Help Book バンドル**: 拡張子 `.help`、UTI `com.apple.help`
- **helpd サービス**: ヘルプブックの検出・インデックス管理を担当
- **Help Viewer**: WebKit ベースのレンダラ（名称・パスは OS バージョンにより異なる）
- **キャッシュ**: `~/Library/Caches/com.apple.helpd/`

### ヘルプブック検出

`/Applications` や `/Applications/Utilities` にアプリが配置されると、システムがヘルプブックを自動検出・登録する。DerivedData からの実行では検出されないケースがある。

---

## 9. Help Viewer キャッシュ — 最大の落とし穴

**Help Viewer (helpd) は非常に強力なキャッシュを持つ**。ヘルプ内容を更新してもキャッシュが返り続ける。新しいヘルプブックの登録にも 10秒〜数分かかることがある。

### キャッシュクリア手順

```bash
# 1. helpd プロセスを停止 (hiutil -P も使える)
killall helpd
# または
hiutil -P

# 2. キャッシュディレクトリを削除
rm -rf ~/Library/Caches/com.apple.helpd/

# 3. クリーンビルド
xcodebuild -scheme Bubilator88 -configuration Debug clean build

# 4. /Applications に再デプロイ
cp -R "$(xcodebuild -scheme Bubilator88 -showBuildSettings 2>/dev/null | \
  grep ' BUILT_PRODUCTS_DIR' | awk '{print $3}')/Bubilator88.app" /Applications/
```

### それでも古い内容が表示される場合

1. ログアウト → ログインで helpd キャッシュが完全にリセットされる
2. `CFBundleVersion` を変更するとキャッシュ無効化に有効（High Sierra 以降はバージョンが識別に含まれるため）
3. "The selected content is currently unavailable" → ヘルプブックが未登録。10分程度待つ

### 開発時のTips

- **必ず `/Applications/` から起動して確認する**。DerivedData 内の .app だと helpd の File System Events 監視範囲外のため、ヘルプブックが発見されない
- helpd のバックグラウンド処理に 10秒以上かかることがある（Apple Silicon でも）
- HelpViewer は最初のページ表示に 2秒以上かかることがある（正常動作）

---

## 10. 既知の問題と対策

### 問題: ヘルプが開かない（汎用 macOS ヘルプが表示される）

**原因候補** (優先度順):
1. `CFBundleHelpBookName` と `HPDBookTitle` が一致しない（**最頻出**）
2. `_access.html` が XHTML 1.1 形式でない（HTML5 だとサイレント失敗）
3. `search.cshelpindex` が旧形式 (typedstream) のまま
4. helpd キャッシュが古い登録情報を持っている
5. アプリが `/Applications` 以外から起動されている

**診断コマンド**:

```bash
# アプリのヘルプブック設定を確認
/usr/libexec/PlistBuddy -c "Print :CFBundleHelpBookName" \
  /Applications/Bubilator88.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleHelpBookFolder" \
  /Applications/Bubilator88.app/Contents/Info.plist

# Help Book の HPDBookTitle を確認（上と一致するか？）
/usr/libexec/PlistBuddy -c "Print :HPDBookTitle" \
  /Applications/Bubilator88.app/Contents/Resources/Bubilator88.help/Contents/Info.plist

# ヘルプブックが正しくバンドルされているか確認
ls /Applications/Bubilator88.app/Contents/Resources/Bubilator88.help/Contents/Resources/

# インデックスのアンカーを確認
hiutil -I corespotlight --list-anchors -f \
  /Applications/Bubilator88.app/Contents/Resources/Bubilator88.help/Contents/Resources/en.lproj/search.cshelpindex

# _access.html のフォーマットを確認 (XHTML 1.1 であること)
head -3 /Applications/Bubilator88.app/Contents/Resources/Bubilator88.help/Contents/Resources/en.lproj/_access.html
```

### 問題: Intel Mac でヘルプウィンドウがアプリの背面に表示される

Howard Oakley 氏によると、Intel Mac では HelpViewer がアプリウィンドウの背面に開く既知バグがある。Apple Silicon では発生しない。

### 問題: Stage Manager との相性

HelpViewer は独立アプリとして動作するため、Stage Manager がアプリと同グループにしたりしなかったりする不安定な挙動がある。

### 問題: ダークモード対応

Help Viewer は WebKit ベースなので CSS メディアクエリが有効：

```css
@media (prefers-color-scheme: dark) {
    body { background: #1D1D1D; color: #E0E0E0; }
}
```

---

## 11. HTML ページのテンプレート

各ヘルプページの基本構造：

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="description" content="Short description for search results">
    <meta name="keywords" content="keyword1, keyword2, synonym, misspelling">
    <meta name="robots" content="index">
    <title>Page Title</title>
    <link rel="stylesheet" href="../../shrd/helpstyle.css">
</head>
<body>
    <a name="anchor-name"></a>
    <h1>Page Title</h1>
    <!-- Content -->
    <p><a href="../index.html">Back to Bubilator88 Help</a></p>
</body>
</html>
```

### メタタグの役割

| メタタグ | 必須 | 説明 |
|---------|------|------|
| `description` | 推奨 | 検索結果に表示される要約文 |
| `keywords` | 推奨 | 検索対象のキーワード（類義語、よくあるタイプミスも含める） |
| `robots` | 推奨 | `index` (検索対象), `noindex` (除外), `KEYWORDS` (キーワードのみ), `ANCHORS` (アンカーのみ) |

### リンクの書き方

```html
<!-- Help Viewer 内でのアンカーリンク -->
<a href="help:anchor=anchor_name bookID=com.bubio.Bubilator88.help">Link text</a>

<!-- Help Viewer 内での検索リンク -->
<a href="help:search='search term' bookID=com.bubio.Bubilator88.help">Search</a>

<!-- ヘルプブックを開くリンク -->
<a href="help:openbook=com.bubio.Bubilator88.help">Open help</a>

<!-- 外部リンク (Help Viewer 内で開く) -->
<a href="https://example.com" target="_helpViewer">External</a>
```

---

## 12. ビルドプロセス

### Xcode Build Phase スクリプト（推奨）

HTML を変更するたびに手動で hiutil を実行するのは忘れやすい。Run Script Build Phase で自動化する：

```bash
set -x
cd "${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.help/Contents/Resources"
for LANGUAGE in *.lproj; do
    pushd "${LANGUAGE}"
    hiutil -I corespotlight -Caf search.cshelpindex -vv .
    hiutil -I lsm -Caf search.helpindex -vv .
    hiutil -I corespotlight -Tvf search.cshelpindex  # バリデーション
    popd
done
```

**Xcode 15+ の注意**: Build Settings > `User Script Sandboxing` を `No` に設定しないと、スクリプトがパーミッションエラーで失敗する。

### ソースツリー内のインデックスについて

Build Phase でインデックスを自動生成する場合、ソースツリー内の `.cshelpindex` / `.helpindex` は不要（ビルド時に生成される）。ただし git にコミットしておくと、ソースから直接ヘルプをプレビューする際に便利。

### コード署名

- Help Book バンドル (.help) 自体は**署名してはならない**
- App Store 提出時: Help Book ターゲットの Code Signing Identity を空文字に設定
- アプリ署名の Sealed Resources に自動的に含まれる

### Help Book のプレビュー方法

- ダブルクリックでは開けない（登録されていないため）
- `~/Library/Documentation/Help/` にコピーすると、アプリなしでもヘルプを閲覧可能
- Jekyll 使用時は `jekyll-server.command` でローカルサーバ起動 → Safari でプレビュー

---

## 13. 開発チェックリスト

新規ヘルプブック作成時、またはヘルプが動作しない時に確認する項目：

- [ ] アプリ Info.plist に `CFBundleHelpBookName` と `CFBundleHelpBookFolder` がある
- [ ] `CFBundleHelpBookName` と Help Book の `HPDBookTitle` が**完全一致**している
- [ ] `_access.html` が **XHTML 1.1** 形式（`<!DOCTYPE html PUBLIC ... xhtml11.dtd">` で始まる）
- [ ] 各 lproj に `_access.html` がある
- [ ] `search.cshelpindex` が `hiutil -I corespotlight` で生成されている
- [ ] `hiutil -I corespotlight --list-anchors -f search.cshelpindex` でアンカーが表示される
- [ ] アプリが `/Applications/` にデプロイされている
- [ ] helpd キャッシュをクリアした（`killall helpd && rm -rf ~/Library/Caches/com.apple.helpd/`）
- [ ] Help Book バンドルに不要なコード署名がない
- [ ] Xcode 15+: `User Script Sandboxing` = `No`（Build Phase スクリプト使用時）
