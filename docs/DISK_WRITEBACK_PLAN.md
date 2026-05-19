# D88 ディスク書き戻し実装計画

## 1. 背景と現状

Bubilator88 は現状、ゲーム内で発生したディスクへの書き込み (ユーザーディスク
のキャラクターセーブ、設定ファイル更新、ハイスコア記録など) を **メモリ上の
`D88Disk` バッファにしか反映しない**。eject やアプリ終了で破棄され、.d88
ファイル自体は変更されないため、ユーザー視点では「保存できないエミュレータ」
に見える。

セーブステート (`.b88s`) には `D88Disk.serialize()` の結果が DSK0/DSK1
セクションとして埋め込まれるので、save state 経由ではディスク状態が保持
されているが、これは本来のディスクメディアとしての永続化とは別。

参照実装は `BubiC-8801MA/src/vm/disk.cpp:740` の `DISK::close()`。本計画は
BubiC を基準に Bubilator88 向けに最適化したものを記述する。

## 2. 設計方針

### 2.1 タイミング (ライトスルー方式)

**書き込み発生時に随時 .d88 へ反映** する。BubiC の eject 時バッチ方式は
採用しない。理由:

- 実機の挙動と一致 — 「セーブ後にリセット技で巻き戻す」が動く
- アプリクラッシュ / 強制終了でもセーブ済みデータが守られる
- ユーザの「保存できた」という感覚と実ファイル状態が一致する
- save state とディスク永続化の役割が明確に分離される

ただし純粋なセクタ毎書込は連続書込時の I/O burst が無駄なので、
**dirty 検出 → 100ms debounce → 全バンク書込** のスケジューラを挟む。

| トリガ | 動作 |
|--------|------|
| `writeSector` / `format` 完了 | `dirty=true` をセットし、書き戻しを 100ms 後に予約 (既存予約があれば延長) |
| Eject / 差し替え | 予約中の書き戻しを即 flush してから処理 |
| アプリ終了 (`applicationWillTerminate`) | 全ドライブの予約を即 flush |
| 起動ディスク変更 reset | flush → eject → mount → reset |
| セーブステート load | **書き戻し不要** (現メモリ状態は破棄される)。ただし debounce 中の書き戻し予約は load 前に flush して、それ以前のセーブを失わない |

100ms 経過前に再度 `dirty` が立った場合はタイマをリセットして再度 100ms
待つ (典型的なセーブ処理の連続セクタ書込をまとめる)。最大遅延を抑えたい
場合は「最初の dirty から最大 500ms」のハードリミットも併用する。

### 2.2 変更検出

`D88Disk` の既存 `dirty: Bool` フラグを利用する。`writeSector` / `format`
で立ち、書き戻し成功時にクリア。書き戻し scheduler は dirty が立った
瞬間にコールバックされる必要があるため、`D88Disk` に変更通知用クロージャ
を 1 本追加:

```swift
var onDirty: (() -> Void)?   // writeSector/format 成功時に呼ばれる
```

ViewModel 側でこのクロージャを受けて debounce 予約を行う。BubiC のような
CRC32 比較は採用しない (debounce で十分まとまるため、誤検知抑制の意義が
薄い)。

### 2.3 書き戻し先

書き戻し先は基本的に `MountedDiskInfo.sourceURL` だが、**アーカイブ
(.zip/.lha) からマウントしたものは展開キャッシュを真のマウント先として
扱う**ことで「常にローカルの単独 .d88 を書き戻す」モデルに統一する。

- **通常 `.d88` 直接マウント**: そのままソース URL に上書き
- **アーカイブ経由マウント**: §2.6 のディスクキャッシュ機構で展開された
  `~/Library/Application Support/Bubilator88/disks/<hash>/<entry>.d88` を
  実マウント先とし、書き戻しもそこに行う。元アーカイブは常に read-only。
- **空ディスク作成直後**: 既に `sourceURL` が存在するのでそのまま上書き

ソース URL も展開キャッシュ URL も nil の場合 (セーブステートから復元した
DSK0 セクションだけある状況など) はリカバリディレクトリへフォールバック:
`~/Library/Application Support/Bubilator88/ModifiedDisks/<sha8>.d88`

### 2.4 マルチイメージ (バンク) D88 の取り扱い

D88 フォーマットは 1 ファイル内に複数ディスクイメージを格納できる。例えば
ゲームの A 面 / B 面が単一 `.d88` の bank 0 / bank 1 になっているケース。

BubiC は変更があったバンクだけ書き換え、前後バンクは元ファイルから読み戻
してそのまま再保存する。Bubilator88 でも同じ方針:

1. `D88Disk` に **元ファイル内のバンク byte range** を保持する。
2. 書き戻し時は、元ファイルを開いて
   `[0..bankStart] + serialize() + [bankEnd..EOF]` を再構築し書き戻す。
3. 元ファイルが消えている / 開けない場合はリカバリディレクトリへ
   フォールバック。

アーカイブ由来のマルチバンク D88 も §2.3 の通り展開キャッシュ内の `.d88`
が「元ファイル」として扱われるので、特別な分岐は不要。

`D88Disk` に追加するメタ:

- `imageIndex: Int` (バンク番号)
- `bankByteRange: Range<Int>?` (元ファイル内オフセット/長さ)

### 2.5 アーカイブ展開キャッシュ (重要)

ZIP/LHA からマウントしたディスクは、初回マウント時にアーカイブを展開して
アプリサポート配下にキャッシュし、**以降の動作はそのキャッシュ済み .d88 を
通常マウントと同等に扱う**。これにより:

- 書き戻しロジックがアーカイブを意識する必要がなくなる
- マルチバンク D88 の前後マージは元キャッシュ .d88 をそのまま使えばよい
- 2 回目以降のマウントでアーカイブ展開コストがかからない
- セーブが自然に永続化される (ユーザー視点で「セーブできるエミュレータ」)

#### 2.5.1 ディレクトリ構造

```
~/Library/Application Support/Bubilator88/
└── disks/
    └── <hash>/
        ├── source.json
        ├── <entry1>.d88
        └── <entry2>.d88
```

`source.json` の内容例:

```json
{
  "originalArchivePath": "/Users/foo/Games/Ys.zip",
  "originalArchiveSize": 412380,
  "hashAlgorithm": "sha256-16+size",
  "hash": "a3f2b1c890d4e567-412380",
  "createdAt": "2026-05-16T10:23:00Z",
  "lastAccessedAt": "2026-05-16T18:45:12Z",
  "entries": [
    { "name": "Ys (Disk A).d88", "size": 348848 },
    { "name": "Ys (Disk B).d88", "size": 348848 }
  ]
}
```

#### 2.5.2 ハッシュ算出

**ハイブリッド方式: `SHA256(file bytes) の先頭 16 桁 + "-" + ファイルサイズ`**

- SHA256: 内容が一致する別パスのアーカイブを同じキャッシュに統合できる
- size 接尾: 衝突回避 + 視認性
- 計算コスト: ZIP/LHA はせいぜい数 MB 〜 数十 MB なので一括読み込み可
- パス/リネームに非依存

iCloud 上のアーカイブで `.icloud` プレースホルダの場合は初回展開時に
`FileManager.startDownloadingUbiquitousItem(at:)` で本体を取得してから
ハッシュ計算する (この 1 回のみ)。

#### 2.5.3 マウントフロー

```
mount(archiveURL, entryName):
  hash = computeHash(archiveURL)
  cacheDir = appSupport/disks/<hash>/
  cachedDiskURL = cacheDir/<entryName>.d88
  if !cachedDiskURL.exists:
    extract(archiveURL, entryName) → cachedDiskURL
    write source.json
  update source.json.lastAccessedAt
  proceed with mountDisk(cachedDiskURL)  # 通常パスと同じ
```

`MountedDiskInfo` には**元アーカイブ URL ではなくキャッシュ URL** を
`sourceURL` として持たせる。元アーカイブ情報は `originArchiveURL` 等の
別フィールドへ。これにより書き戻しは通常 .d88 と全く同じコードパスで完了。

#### 2.5.4 アーカイブ更新時の挙動

ユーザーがアーカイブを更新版に置き換えると hash が変わり、新キャッシュ
ディレクトリが作成される。**古いキャッシュは自動削除しない** (ユーザーの
セーブが残っているかもしれないため)。設定画面の「ディスクキャッシュ管理」
から手動削除可能。

#### 2.5.5 キャッシュ管理ポリシー

- 自動削除しない (default)
- 設定画面に「キャッシュ使用量 XX MB / 個別削除 / 全削除」UI を提供
- オプションで「N 日参照なしのキャッシュを削除」(将来検討)

#### 2.5.6 アーカイブ削除後の動作

元アーカイブが消えても、キャッシュ + `source.json` だけで mount 継続可能。
UI には `source.json.originalArchivePath` を表示しつつ「元アーカイブが見
つかりません (キャッシュから動作中)」と注記。

#### 2.5.7 エントリ名の正規化

Shift_JIS の LHA など、日本語エントリ名を含むものは **NFC 正規化** して
ファイル名にする。比較は常に NFC で行う。

### 2.6 ライトプロテクト

`D88Disk.writeProtected` が true なら `writeSector()` は既に失敗するので、
書き戻しもそもそも発生しない (dirty が立たない)。BubiC のフォールバック
(write_protected コメントアウト) は採用しない方が安全。

ファイルシステム側の read-only や、外部ボリュームのアンマウントによる書き
込み失敗もありうる。失敗時はリカバリディレクトリにフォールバックし、UI で
通知する。

## 3. 設定 (Settings)

`Settings` に以下を追加:

| キー | 型 | デフォルト | 説明 |
|------|-----|----------|------|
| ~~`diskWriteBackEnabled`~~ | ~~Bool~~ | ~~true~~ | 不要 (常時有効) |
| ~~`diskWriteBackMode`~~ | ~~String~~ | ~~"auto"~~ | 不要 (auto 固定) |

設定項目は追加しない。書き戻しは常時 auto モードで動作する。

## 4. UI 変更

UI 追加は行わない (常時 auto モード、PR #43 のキャッシュエクスポートで
救済済)。

## 5. 実装ステップ

### Phase 1: コア書き戻し (単独 D88 / ライトスルー)
1. `D88Disk` に追加:
   - `imageIndex: Int` (バンク番号)
   - `bankByteRange: Range<Int>?` (元ファイル内オフセット/長さ)
   - `onDirty: (() -> Void)?` (writeSector/format 成功時に呼ばれる)
2. `D88Disk.parse(data:imageIndex:)` でロード時にバンク範囲を記録
3. `D88Disk.serializeBank()` を新設 (バンクのみのバイト列を返す)
4. `DiskWriteBackScheduler` を新設 (`EmulatorViewModel` 内 or 独立クラス)
   - ドライブごとに debounce タイマを持つ
   - `schedule(drive:)`: 既存タイマをリセット → 100ms 後に flush 発火
   - `flushNow(drive:)`: タイマ即発火 (eject/終了時)
   - `flushAll()`: 全ドライブ即 flush
   - 最大遅延 500ms のハードリミット
5. `writeBack(drive:)` (実書込関数) を実装
   - `dirty == false` なら何もしない (no-op)
   - `sourceURL` 有 → 書き戻し (マルチバンクは元ファイルから前後をマージ)
   - 書き込み失敗 → リカバリディレクトリへフォールバック
   - 成功時 `dirty = false` をクリア
6. ドライブマウント時に `D88Disk.onDirty = { scheduler.schedule(drive:) }` を設定
7. `ejectDisk(drive:)` の先頭で `scheduler.flushNow(drive:)` を呼ぶ
8. `Bubilator88App` の `.applicationWillTerminate` 相当で `flushAll()`
9. `mountDisk` 系で既存ドライブを置き換える直前にも `flushNow`
10. save state load 直前に `flushAll()`

この Phase の時点ではアーカイブ経由マウントは旧挙動 (メモリのみ) のまま。

### Phase 2: アーカイブ展開キャッシュ機構
1. `DiskCacheManager` を新設
   - `~/Library/Application Support/Bubilator88/disks/<hash>/` 管理
   - `computeHash(url)` (SHA256 先頭 16 + size)
   - `source.json` の読み書き
   - 既存キャッシュの hit / miss 判定
2. アーカイブマウントフロー (`EmulatorViewModel+Disk.swift`) を改修
   - 初回: 展開してキャッシュ作成
   - 2 回目以降: キャッシュ済み `.d88` を直接 mount
3. `MountedDiskInfo` を変更
   - `sourceURL` = キャッシュ URL (実マウント先)
   - `originArchiveURL` / `originArchiveEntryName` を別フィールドに
4. `recentDiskFiles` のレコード変換 (旧データの自動マイグレーション)
5. iCloud アーカイブの自動ダウンロード対応

### Phase 3: UI / 設定
1. ~~Settings に `diskWriteBackEnabled` / `diskWriteBackMode` 追加~~ — 不要
2. ~~SettingsView にトグル + セグメント追加~~ — 不要
3. ~~SettingsView に「ディスクキャッシュ管理」セクション~~ — 不要
   - 代替: PR #43 の「キャッシュをエクスポート」メニューで救済済
4. ~~File メニューに「ドライブ N のディスクを保存」追加~~ — 不要 (auto モード固定)
5. ~~トースト/アラート整備~~ — 不要
6. ~~元アーカイブが見つからないキャッシュへの注記表示~~ — PR #43 で救済済

### Phase 4: 互換テスト
1. Regression: 既存 15 タイトルのブートを変更なしで通すこと
2. 専用テスト:
   - ユーザディスク作成 → セーブ → eject → 再 mount → データ存在
   - **セーブ → debounce 経過待ち → アプリ強制終了 → 再起動 → データ存在**
     (ライトスルー方式の核となる検証)
   - **セーブ → エミュレータリセット (Cmd+R) → ブート直後にロード → データ存在**
     (リセット技の動作確認)
   - ZIP からマウント → セーブ → アプリ終了 → 再起動 → 再 mount で
     データ存在 (キャッシュ機構 + ライトスルーの組合せ)
   - マルチバンク D88 で bank 0 を変更 → bank 1 が保持されていること
   - read-only ファイルへのセーブ → リカバリディレクトリにフォールバック
   - アーカイブ更新で hash 変化 → 新キャッシュ作成 / 旧キャッシュ保持
   - 連続セクタ書込 (大きなセーブ) → 1 回の書き戻しにまとまっていること
     (Phase 1 debounce 動作確認)

## 6. 後方互換と既存ユーザへの影響

- デフォルト ON にするか OFF にするかは要検討。OFF だと「保存できないまま」
  という既存挙動が継続するので、初期実装は **デフォルト ON** とする。
- 既存 `.d88` ファイルが書き換わるため、ユーザーは元データを失う可能性が
  ある。初回起動時に一度だけ「自動書き戻しが有効です」と通知し、設定への
  リンクを提示することを検討。

## 7. 未決事項 (全 8 項目 2026-05-19 決着)

1. **confirm モード不要で確定** — ライトスルーで「保存し忘れ」概念がない。
   リードオンリーが欲しければ `toggleWriteProtect` でカバー済
2. **セーブステート load 時の警告不要で確定** — `performLoad` 冒頭で
   `diskWriteBackScheduler.flushAll()` を呼んで先に永続化済
   (`EmulatorViewModel.swift:1098`)
3. **キャッシュ・リカバリとも自動削除なし / 上限なしで確定** —
   `feedback_save_data_never_auto_delete` に従う。キャッシュは
   「キャッシュをエクスポート」(PR #43) + Finder 手動削除でユーザ管理。
   `ModifiedDisks/` は失敗時バックアップなので Finder で直接管理
4. **書き戻し失敗時のリトライ機構不要で確定** — 現状の
   「`dirty=true` 復元 → 次セクタ書込で自動再試行 + recovery dir
   フォールバック + alert」の 3 段で十分。明示リトライは alert を
   遅延させるデメリットの方が大きい
5. **iCloud Drive 直接マウント: 専用対応なしで確定** —
   `Data(contentsOf:)` + `.atomic` write が iCloud Drive を透過的に
   ハンドル。実機テストで mount/save とも正常動作確認済
   (履歴のパスが物理パス `~/Library/Mobile Documents/com~apple~CloudDocs/`
   のまま見えるのは許容)
6. **キャッシュ hit/miss は hash + size のみで確定 (mtime 不採用)** —
   同一バイト列で mtime だけ変わったケース (クラウド同期 / touch) で
   無駄展開されると、旧キャッシュ内のセーブデータが見えなくなる方が
   重大バグなので mtime は使わない
7. **debounce 100ms 固定で確定** — regression 15 本 + ユーザ実機検証で
   100ms 動作確認済。50ms は応答性過多で SAVE 中の取りこぼし懸念、
   200ms は強制終了時の損失幅増
8. **partial write 最適化は着手せず、Phase 5 候補のまま** —
   1MB atomic write は SSD で 10ms 未満で完了 + atomic 性によって
   クラッシュセーフ。partial write は seek/write 中の電源断で
   ファイル整合性が壊れるリスクがある。実害が報告されたら検討

## 8. 参照

- BubiC 実装: `~/dev/_Emu/BubiC-8801MA/src/vm/disk.cpp:740 DISK::close()`
- BubiC 呼び出し点: `upd765a.cpp:200 (release)` / `upd765a.cpp:1683 (close_disk)`
- 既存 `D88Disk`: `Packages/EmulatorCore/Sources/Peripherals/D88Disk.swift`
- 既存セーブステート埋め込み: `EmulatorCore/SaveStateSerialize.swift:701-705`
- 永続化全般: `docs/PERSISTENCE.md`
