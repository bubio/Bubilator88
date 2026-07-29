# 起動引数 — `bubilator88://` URL スキーム と CLI

FlipDisk（自前ランチャー）などの外部ランチャーやシェルから、Bubilator88 に
ディスク/機種/クロックを指定して起動（差し替え）するための仕組み。
**引数の書式は QUASI88 と完全に同じ**（`QUASI88/doc/manual.txt` の
「書式」「オプション」）で、URL 経由でも CLI 経由でも同じパーサを通る。
設計判断の経緯は [URL_SCHEME_LAUNCH_PLAN.md](URL_SCHEME_LAUNCH_PLAN.md) を参照。

## 書式

```
[-option ...] image-file [image-No] [image-file [image-No]]
```

- `-` で始まらない引数が**イメージファイル**。1 個目が drive 1:（内部の
  drive 0）、2 個目が drive 2:（drive 1）。3 個目以降は QUASI88 と同じく無視。
- ファイル名の直後に続く数値が**イメージ番号（1 始まり）**。
  `-` で始まらないファイル名の後、数値が続く限り読む。
- イメージ番号を省略したときの割り当ては QUASI88 と同一:

| 指定 | drive 1: | drive 2: |
|------|----------|----------|
| `a.d88`（単一面） | a.d88 面1 | 空 |
| `x.d88`（複数面） | x.d88 面1 | **x.d88 面2** |
| `x.d88 3` | x.d88 面3 | 空 |
| `x.d88 2 4` | x.d88 面2 | x.d88 面4 |
| `a.d88 b.d88` | a.d88 面1 | b.d88 面1 |
| `x.d88 3 y.d88` | x.d88 面3 | y.d88 面1 |
| `x.d88 y.d88 3` | x.d88 面1 | y.d88 面3 |
| `x.d88 4 y.d88 2` | x.d88 面4 | y.d88 面2 |

### m3u / m3u8 プレイリスト

イメージファイルには `.m3u` / `.m3u8` プレイリストも指定できる。**プレイリスト
の「エントリ」を d88 の「面」と同じものとして扱う**ので、イメージ番号の書式も
割り当て規則も d88 とまったく同じ（イメージ番号 = エントリ番号、1 始まり）:

| 指定 | drive 1: | drive 2: |
|------|----------|----------|
| `p.m3u`（エントリ 2 件以上） | エントリ1 | **エントリ2** |
| `p.m3u`（エントリ 1 件） | エントリ1 | 空 |
| `p.m3u 3` | エントリ3 | 空 |
| `p.m3u 2 4` | エントリ2 | エントリ4 |

各エントリは**独立したソースファイル**として、その 1 面目がマウントされる
（GUI の m3u マウントと同じ規則。ディスク書き戻しがエントリ自身のファイルに
向くよう、複数面をフラット化した共有イメージリストにはしない）。エントリが
複数面を持つ場合、面の切り替えは従来どおりドライブのイメージメニューから行う。

**制約** — 以下はすべてエラーになり、**何も変更されない**:

- d88 との混在（`p.m3u a.d88` / `a.d88 p.m3u` など）
- プレイリストの複数指定（`p.m3u q.m3u8`）
- 結果としてプレイリスト指定時にファイル引数は**常に 1 個**。d88 で言う
  `a.d88 b.d88` / `x.d88 3 y.d88` / `x.d88 y.d88 3` / `x.d88 4 y.d88 2`
  に相当する 2 ファイル形式は使えない。

プレイリストの書式は従来どおり、1 行 1 パス、空行と `#` 始まりのコメントは無視、
エントリの相対パスは**プレイリスト自身のディレクトリ基準**。

### オプション

| オプション | 意味 |
|-----------|------|
| `-v2` / `-v1h` / `-v1s` / `-n` | 起動モード。省略時は現在の設定を維持 |
| `-4mhz` / `-8mhz` | CPU クロック。省略時は現在の設定を維持 |
| `-romboot` / `-diskboot` | 起動ストラップ（DIPSW2 bit3）。省略時は drive 0 の状態から自動判定 |

大文字小文字は無視。排他オプションを複数書いた場合は**最後の指定が有効**
（QUASI88 manual.txt:74-76 と同じ）。上表以外のオプションはエラーになる
（QUASI88 は警告して読み飛ばすが、本実装はランチャー側の誤りを黙って
飲み込まないためエラーにする）。

`-h` / `-help` / `--help` は特別扱い: 他の引数を一切解釈せず、使い方を
**stdout に print して `exit(0)`** する（GUI は一度も起動しない）。実行
ファイルを直接叩いたときだけ見える（`open` 経由だと stdout がターミナル
に継承されないため出力は見えない）。URL スキーム側では意味を持たない
（`bubilator88://boot?arg=--help` は他の未知オプションと同じくエラーになる）。

`-dipsw` は未対応: QUASI88 の値は N88-BASIC の `NEW ON` 引数のセマンティクス
で、Bubilator88 の `dipSw1`/`dipSw2Base`（ポート 0x30/0x31 の生ビット）とは
別のエンコードであり、機械的な対応付けができないため。

## URL スキーム

```
bubilator88://boot?arg=<argv[0]>&arg=<argv[1]>&…
```

argv の 1 要素を `arg` クエリ項目 1 個で表す。**順序は保存される**。
host は `boot` 固定（未知 host はエラー）。

例:
```
bubilator88://boot?arg=-v1h&arg=-4mhz&arg=%2FVolumes%2FCrucialX6%2Froms%2FPC88%2FTEST%2F%E3%82%A4%E3%83%BC%E3%82%B9.d88
bubilator88://boot?arg=-v2&arg=%2Fx%2Fx.d88&arg=2&arg=4
```

- パスは必ず percent-encoding された文字列で渡すこと。PC-88 タイトルは
  日本語・スペース混じりのファイル名が常態なので、送信側 (FlipDisk) は
  `Uri`/`URLComponents` などの API で組み立て、**文字列連結や手動
  percent-encoding をしないこと**。1 引数 = 1 `arg` 項目にすることで、
  引数区切りのクォート規則を自前で持たずに済む設計。
- **URL 経由のパスは絶対パス必須**（`~` 展開は可）。相対パスの基準となる
  作業ディレクトリが存在しないため、相対パスはエラーになる。

## CLI

**起動時**のプロセス引数を同じ書式で解釈する。

```bash
# 実行ファイルを直接叩く（シェルの作業ディレクトリを継承する）
/Applications/Bubilator88.app/Contents/MacOS/Bubilator88 -v1h -4mhz ~/disks/イース.d88

# open 経由（新規起動時のみ、絶対パス必須）
open -a Bubilator88 --args -v2 /x/x.d88 2 4
open -n -a Bubilator88 --args -v2 /x/x.d88 2 4   # -n で強制的に新インスタンス
```

- 引数が（システム注入分を除いて）空なら何もしない = 通常起動。
- 相対パスは**プロセスの作業ディレクトリ基準**で解決される。`~` は展開される。
- **`open` 経由だと作業ディレクトリは `/` になる**（`open` を実行したシェルの
  cwd は継承されない。`lsof -d cwd` で実測確認済み）。つまり
  `open --args` に**相対パスを渡してはいけない** — 必ず絶対パスにすること。
  相対パスで気軽に叩きたいときは実行ファイルを直接起動する。
- 引数は**起動時に一度だけ**評価される。`open --args` は既に起動中の
  インスタンスには引数を渡さない（前面化するだけ、macOS の仕様）ので、
  実行中インスタンスの差し替えには URL スキームを使うこと。

| 起動方法 | 引数 | 相対パス | 起動中インスタンスへ |
|---------|------|---------|------------------|
| `…app/Contents/MacOS/Bubilator88 <args>` | 届く | 効く | ― |
| `open -a … --args <args>` | 新規起動時のみ | 効かない (cwd=`/`) | 届かない |
| `bubilator88://boot?arg=…` | 届く | 非対応（絶対パス必須） | **届く** |
- macOS / Xcode が注入する `-psn_0_…`、`-NSFoo VALUE`、`-AppleBar VALUE`、
  `-XCFoo VALUE` は解析前に除去される（値の側が `-` で始まらないため、
  除去しないとイメージファイル名として誤解釈される）。

## 動作（URL / CLI 共通）

- **単一インスタンス差し替え**: 新しいウィンドウは開かない。実行中のインス
  タンスがあれば、そのままディスク/機種/クロックを差し替えて cold reset する。
  起動していなければコールド起動してから同じ処理を行う。
- **全 disk-spec を検証してから mount** (xm8 semantics): ファイルが読めるか、
  D88 としてパースできるか、指定イメージ番号が実在する面数以内かを
  **先にすべて検証** する。1件でも失敗した場合は **何も変更せず**
  エラーアラートを出す（現在動いているゲームはそのまま）。存在しない面への
  丸め込みは行わない（QUASI88 は範囲外番号を 1 に丸めるが、ランチャーからの
  指定ミスを隠さないためエラーにする）。
- 引数で指定されなかったドライブは eject される。
- **system/clock は永続設定として保存される**: xm8 と異なり、セッション限定
  ではなく通常の `Settings` に書き込まれる（次回 FlipDisk 起動でどうせ
  上書きされるため実害がない設計判断）。省略時は現在の設定を変更しない。

## 未対応

- `-dipsw` / `-extram` / `-sd` 等、上表以外の QUASI88 オプション
- xm8 の `8H` (8MHz-H)
- `.d88` の Finder ダブルクリック/ドラッグ起動

## 実装

- プレイリスト解析: `Bubilator88/ViewModel/M3UPlaylist.swift`（純粋ヘルパ。
  起動引数と GUI の `mountM3U` が共有。`.m3u8` は GUI のファイルオープン /
  ドラッグ&ドロップでも開けるようになった）
- パーサ: `Bubilator88/ViewModel/LaunchRequest.swift`（純粋関数。イメージ番号
  省略時のドライブ割り当ては実イメージ数に依存するため、`parse` は
  `imageIndex: nil` のまま保持し、`resolveMounts` が面数を受け取って確定する）。
  単体テストは `Bubilator88Tests/LaunchRequestTests.swift`（QUASI88 マニュアルの
  書式例 8 件をそのまま収録）
- 配線: `Bubilator88/ViewModel/EmulatorViewModel+Launch.swift`
  (`requestLaunch(url:)` / `requestLaunchFromCommandLine()` /
  `consumePendingLaunch()` / `performLaunch(_:)`)。URL も CLI も
  `LaunchRequest` に正規化してから同一の検証 → 適用パスを通る
- `--help`: `LaunchRequest.wantsHelp(_:)` / `LaunchRequest.usageText`
  （純粋関数、`Bubilator88/ViewModel/LaunchRequest.swift`）。呼び出しは
  `Bubilator88/App/AppDelegate.swift` の `override init()` 冒頭 — プロセス内
  で `NSApplication` がウィンドウを作るより前に判定できる唯一のフックのため
- Info.plist: `CFBundleURLTypes` に scheme `bubilator88` を登録
- FlipDisk 側: **Bubilator88 固有のコードは持たない**。URL テンプレートは
  エミュレータ登録データ (`Emulator.arguments`) で、`lib/services/placeholder.dart`
  の `buildLaunchUrl` が汎用に展開する (`?` 以降を `&` で分割し、各要素内の
  プレースホルダー値だけを `Uri.encodeComponent` でエンコード。空に展開された
  要素は丸ごと省略)。本仕様に対応する登録内容 (対応済み, 2026-07-28):

  ```
  Arguments: bubilator88://boot?arg=-{system}&arg=-{clock}mhz&arg={rom}
  paramDefs: system = choice V1S|V1H|V2|N (default V2)
             clock  = choice 4|8          (default 4)
  ```

  イメージ番号を省略すると本エミュレータ側が自動割り当てするので、FlipDisk
  側に bank パラメータは持たせない。特定の面を指定したい場合は
  `arg={image0}&arg={image1}` のような text 型パラメータを `{rom}` の直後に
  足す (**1 始まり**。FlipDisk の `bank` 型が扱う 0 始まりのバンク番号とは
  基準が違う)。詳細は FlipDisk の `docs/dev/FlipDisk_Specification_v3.md` §8.2
