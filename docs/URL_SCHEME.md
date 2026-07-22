# URL スキーム起動 — `bubilator88://`

FlipDisk（自前ランチャー）などの外部ランチャーから、単一インスタンスの
Bubilator88 にディスク/機種/クロックを指定して起動（差し替え）するための
URL スキーム。xm8 の CLI 仕様と同じセマンティクスを踏襲するが、構文は
argv ではなく URL クエリパラメータ。設計判断の経緯は
[URL_SCHEME_LAUNCH_PLAN.md](URL_SCHEME_LAUNCH_PLAN.md) を参照。

## フォーマット

```
bubilator88://boot?disk0=<path>&bank0=<n>&disk1=<path>&bank1=<n>&system=<sys>&clock=<clk>
```

| query key | 必須 | 値 | 説明 |
|-----------|------|----|------|
| `disk0` | ○ | percent-encoded 絶対パス | drive 0 に載せる D88 |
| `bank0` | × | 0 以上の10進 | drive 0 の面 (imageIndex)。省略時 0 |
| `disk1` | × | percent-encoded 絶対パス | drive 1 に載せる D88。省略 = drive 1 を eject |
| `bank1` | × | 0 以上の10進 | drive 1 の面。省略時 0 |
| `system` | × | `V1S`/`V1H`/`V2`/`N`（大小無視） | 起動モード。省略時は現在の設定を維持 |
| `clock` | × | `4`/`4MHz`/`8`/`8MHz`（大小無視） | CPU クロック。省略時は現在の設定を維持 |

host は `boot` 固定（未知 host はエラー）。

例:
```
bubilator88://boot?disk0=%2FVolumes%2FCrucialX6%2Froms%2FPC88%2FTEST%2F%E3%82%A4%E3%83%BC%E3%82%B9.d88&system=V1H&clock=4
bubilator88://boot?disk0=/x/sys.d88&bank0=0&disk1=/x/data.d88&bank1=2&system=V2
```

## 動作

- **単一インスタンス差し替え**: 新しいウィンドウは開かない。実行中のインス
  タンスがあれば、そのままディスク/機種/クロックを差し替えて cold reset する。
  起動していなければコールド起動してから同じ処理を行う。
- **全 disk-spec を検証してから mount** (xm8 semantics): `disk0`/`disk1` の
  ファイルが読めるか、D88 としてパースできるか、指定 `bank` が実在する面数
  以内かを **先にすべて検証** する。1件でも失敗した場合は **何も変更せず**
  エラーアラートを出す（現在動いているゲームはそのまま）。存在しない bank
  への丸め込みは行わない。
- **system/clock は永続設定として保存される**: xm8 と異なり、セッション限定
  ではなく通常の `Settings` に書き込まれる（次回 FlipDisk 起動でどうせ
  上書きされるため実害がない設計判断）。省略時は現在の設定を変更しない。
- パスは必ず percent-encoding された文字列で渡すこと。PC-88 タイトルは
  日本語・スペース混じりのファイル名が常態なので、送信側 (FlipDisk) は
  `Uri`/`URLComponents` などの API で組み立て、**文字列連結や手動
  percent-encoding をしないこと**。

## 未対応 (初版)

- `.m3u` プレイリストの URL 経由 mount（`disk0`/`disk1` は `.d88` のみ）
- xm8 の `8H` (8MHz-H) — `clock` は `4`/`8` の二値のみ
- ターミナルからの literal argv 起動（`bubilator88 game.d88` 形式）
- `.d88` の Finder ダブルクリック/ドラッグ起動

## 実装

- パーサ: `Bubilator88/ViewModel/LaunchRequest.swift`（純粋関数、単体テストは
  `Bubilator88Tests/LaunchRequestTests.swift`）
- 配線: `Bubilator88/ViewModel/EmulatorViewModel+Launch.swift`
  (`requestLaunch` / `consumePendingLaunch` / `performLaunch`)
- Info.plist: `CFBundleURLTypes` に scheme `bubilator88` を登録
- FlipDisk 側: `lib/services/launcher.dart` の `buildBubilator88LaunchUri` /
  `isBubilator88Executable`（executable が `Bubilator88.app` のときだけ
  この経路を通り、それ以外は既存の generic な `arguments` テンプレート展開
  を使う）。ゲーム別の `disk1`/`bank0`/`bank1`/`system`/`clock` は FlipDisk
  の汎用 `Game.params`（`Emulator.paramDefs` で自由なキーを定義できる仕組み、
  xm8 の `bank1`/`bank2` パラメータと同じ）から読む。
