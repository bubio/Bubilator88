# Scripting — タイムライン操作スクリプト

> **ステータス**: パーサ + 再生エンジン (`ScriptPlayer`) + BootTester の `--script`
> まで実装済み (§11 の手順 1〜3)。GUI アプリの読込/再生/録画 UI (手順 4) は未着手。

---

## 1. 目的

何を起動し (ファイルパス・ブートモード・クロック)、どう操作するか
(キー入力・ディスク入れ替え・リセット等) を、時刻つきの操作列としてテキストで記述し、
エミュレータに再生させる。これを **GUI アプリと BootTester の両方**で使えるようにする。

- **GUI アプリ**: 一般ユーザーがゲーム起動手順やデモ飛ばしをマクロ化して共有できる。
  将来は「プレイ操作を記録してスクリプト化」する録画機能を載せる。
- **BootTester**: 現在 47 個ある `BOOTTEST_*` 環境変数の大半を `--script file.txt`
  一個に畳む。CI・regression・探索・検証の駆動を 1 ファイルで表現する。

スクリプトは**自己完結**する。冒頭のセットアップ (§4) でロード対象・ブートモード・
クロックまで指定するため、スクリプト + ROM だけで再現が成立する (→ §8 決定性)。
両フロントエンドは同じ**再生エンジン (ScriptPlayer)** を共有する (→ §7)。

---

## 2. 時間軸

- **正準はフレーム**。PC-8801 は 60fps 固定なので 1 フレーム = 1/60 秒。
- **秒は糖衣**。`1.5s` のような秒表記は内部でフレームに換算する:
  `frames = round(seconds × 60)` (例 `1.5s` → 90f, `1s` → 60f)。
- 時刻は**相対 (逐次)**。各ステップは記述順に実行され、`wait` だけが時間を進める。
  途中にステップを挿入しても以降の時刻がずれない (手編集・録画と相性が良い)。

### 時間表記

| 表記 | 意味 |
|------|------|
| `90` / `90f` | 90 フレーム |
| `1.5s` | 1.5 秒 = 90 フレーム |

`ms` 表記は v2 以降で検討。

---

## 3. ファイル形式

- 1 行 1 ステップ。トークンは空白区切り。
- `#` 以降は行末までコメント。空行は無視。
- 空白を含むパスは `"..."` で囲む。
- 動詞・キー名・モード名は**大文字小文字を区別しない** (`RETURN` = `return`)。
- スクリプトは 2 部構成: **セットアップ (§4)** → **タイムライン (§5)**。
  セットアップ・ディレクティブは最初の時間進行 (`wait` 等) より前に置く。

### 文法 (EBNF 風)

```
script    = { line }
line      = [ stmt ] [ comment ] newline
stmt      = setup | step
setup     = boot | clock | mount | dipsw
step      = wait | key | disk | reset

boot      = ("boot" | "bootmode") modename
clock     = "clock" ("4" | "8")            ; MHz
mount     = "disk" drive path [ "image" index ]   ; 初期マウント (image 省略時 0)
dipsw     = ("dipsw1" | "dipsw2") byte

wait      = "wait" duration
key       = "key" keyname ("down" | "up" | "tap" [ hold ])
disk      = "disk" ( "swap"   drive path [ "image" index ]   ; 別ファイルに入れ替え
                   | "select" drive index                    ; 同一ファイルのイメージ切替
                   | "eject"  drive )
reset     = "reset" [ "cold" | "warm" ]

duration  = integer [ "f" ] | number "s"
hold      = integer            ; tap の押下フレーム数 (1 以上, 既定 2)
drive     = "0" | "1"
index     = integer            ; multi-image D88 のイメージ番号 (既定 0)
byte      = "0x" hex | integer
modename  = "N88-V2" | "N88-V1H" | "N88-V1S" | "N-BASIC"
path      = quoted-string | bare-word
comment   = "#" { any-char }
```

---

## 4. セットアップ・ディレクティブ

スクリプト冒頭でマシンを構成する。最初の時間進行ステップより前に置くこと
(後置した場合、`boot`/`clock`/`dipsw*` は次回 `reset` 時にのみ反映される)。

| ディレクティブ | 構文 | 動作 |
|----------------|------|------|
| `boot`  | `boot <mode>` | ブートモードを設定 (DIPSW1+2 をまとめて設定)。下表参照。 |
| `clock` | `clock <4\|8>` | CPU クロック (MHz)。 |
| `disk`  | `disk <drive> <path> [image <index>]` | 起動前にドライブ (0/1) へ D88 を初期マウント。`image` 省略時 0。1 ファイルに複数面 (Disk A=image 0, B=image 1…) を含む multi-image D88 はイメージ番号で選ぶ。 |
| `dipsw1`/`dipsw2` | `dipsw1 <byte>` | DIP SW を生値で上書き (`boot` の代わり / 微調整)。 |

### ブートモード対応表

`boot` の名前は DIPSW1/DIPSW2 の組に展開される
(値は `docs/BOOTTESTER.md` / `docs/PERSISTENCE.md` 準拠)。

| mode | DIPSW1 | DIPSW2 | 説明 |
|------|--------|--------|------|
| `N88-V2`  | `0xC3` | `0x71` | N88-BASIC V2 (既定) |
| `N88-V1H` | `0xC3` | `0xF1` | N88-BASIC V1H |
| `N88-V1S` | `0xC3` | `0xB1` | N88-BASIC V1S |
| `N-BASIC` | `0xC2` | `0x71` | N-BASIC (N80) |

- ROM 起動 / ディスク起動の選択 (DIPSW2 bit 3) は、ドライブ 0 の状態から
  リセット時に自動設定される (既存の自動切替挙動)。`dipsw2` で明示上書きも可。
- **省略時の既定**: `boot` 無指定なら `N88-V2`、`clock` 無指定なら 4MHz
  (アプリ実行時は現在のアプリ設定を引き継ぐ)。再現性のため**常に明示を推奨**。

---

## 5. タイムライン動詞 (v1)

| 動詞 | 構文 | 動作 |
|------|------|------|
| `wait` | `wait <duration>` | エミュレータを指定時間進める。**時間を消費する唯一の動詞**。 |
| `key`  | `key <name> down` | キーを押下し続ける (matrix bit clear)。 |
|        | `key <name> up` | キーを離す (matrix bit set)。 |
|        | `key <name> tap [hold]` | 押下し、`hold` フレーム後 (既定 2) に自動リリースを予約 (→ §6)。 |
| `disk` | `disk swap <drive> <path> [image <index>]` | 実行中に**別ファイル**へ入れ替え (ドア遅延あり → §7)。 |
|        | `disk select <drive> <index>` | **同一マウント中ファイル**のイメージ番号を切替 (再読込なし)。 |
|        | `disk eject <drive>` | ドライブを排出。 |
| `reset`| `reset [cold\|warm]` | リセット。既定 `cold`。`warm` は RAM/VRAM 保持。 |

### 予定 (v2 以降)

`tape mount/eject/rewind` ・ `savestate <name>` / `loadstate <name>` ・
`clock` の実行中変更 ・ ヘッドレス用 `screenshot <path>` ・
ボット用条件待ち `waitfor <pc==XXXX | ram[addr]==val>`。

---

## 6. `tap` のセマンティクス

`key X tap` は X を**今**押下し、その後 `hold` フレーム (既定 2) 経過した時点で
自動的に離す**予約**を入れる。リリースは次の `wait` の進行中に発火する。

これにより、利用者が `down`/`up` を手で挟まずとも 1 行でキー入力を表現でき、
かつ押下が必ず 1 フレーム以上保持される (ハードが入力を取りこぼさない) ことを保証する。
タイミングの drift も起きない。

- 同じキーへ保持中に再度 `tap`/`down` が来たら、先に強制リリースしてから処理する。
- 複数キーの `tap` はそれぞれ独立に追跡する。
- スクリプト終了時に未リリースの予約が残っていれば、終了処理で離す。
- `hold` は 1 未満を許さない (パーサが拒否し、念のため再生側でも 1 に丸める)。

キーを**長く保持**したい場合は `tap` ではなく明示的に書く:

```
key SHIFT down
wait 120
key SHIFT up
```

---

## 7. ディスク入れ替えの注意

`disk swap` (別ファイル) と `disk select` (同一ファイルのイメージ切替) はどちらも
`SubSystem.mountDisk` / `switchDiskImage` を経由する。**既にディスクが入っている
ドライブを入れ替える場合**、実機のドア開閉窓を再現するため約 100ms (sub-CPU T-state 換算)
の遅延後に新ディスクが読めるようになる (`pendingMount`)。ディスク交換を検出するゲームの
挙動を正しく再現するための仕様なので、入れ替え直後に即読み出すスクリプトは
この遅延を見込んで `wait` を入れること。

**multi-image D88 の使い分け**: 1 ファイルに Disk A/B 両面を含む場合は
`disk select <drive> <index>` でイメージ番号だけ切り替える (ファイル再読込なし)。
物理的に別の D88 ファイルへ替えるときだけ `disk swap <drive> <path>` を使う。
`image <index>` は省略時 0 (先頭イメージ)。

---

## 8. アーキテクチャ

```
        ScriptPlayer (純 Swift, platform 非依存)
        ├─ Parser:  テキスト → [ScriptStep]
        └─ Player:  カーソルを進め Machine の public API を駆動
                    (keyboard.pressKey / subSystem.mountDisk /
                     machine.reset / runFrame で時間進行)
              ▲                              ▲
   ┌──────────┴──────────┐      ┌────────────┴────────────┐
   │ GUI アプリ           │      │ BootTester              │
   │ スクリプト読込/再生   │      │ --script file.txt       │
   │ (将来: 操作の録画)    │      │ (env-var の大半を置換)   │
   └─────────────────────┘      └─────────────────────────┘
```

- `ScriptPlayer` は `Machine` の public API を叩くだけの薄い層。LSI クラスは追加しない。
- アプリ再生は **drive モード** (スクリプトが時計を所有し、自走 60Hz を止めて
  フレームステップで再生) を基本とする。決定性が必要な検証もここで効く。
- BootTester は単純な同期再生 (ヘッドレス・最大 turbo 可)。`--script` がディスクや
  ブートモードまで含むため、disk 引数や `BOOTTEST_DIPSW*` 等は不要 (スクリプトが優先)。

---

## 9. 決定性

スクリプトの再生結果は `(ROM, スクリプト)` の純関数 (スクリプトが DIPSW・クロック・
ファイルパスを内包するため)。core に乱数はないので、以下を満たせば bit-exact に再現する:

- **virtual RTC を有効化** (RTC を `totalTStates` ベースの固定時刻に置換)。
  BootTester の `--script` では既定 ON (実装済み。`BOOTTEST_VIRTUAL_RTC=0` で無効化可)。
- save state メタの生成時刻 (`Date()`) はエミュレーション状態に影響しない
  (検証ハッシュからは除外する)。

実時間で自走する観測 (live) モードは best-effort で、決定性は保証しない。

---

## 10. 例

```
# Ys を起動してデモを飛ばし、Disk B に入れ替える
# (Ys.d88 は 1 ファイルに Disk A=image 0 / Disk B=image 1 を内包)

# --- setup ---
boot   N88-V2
clock  8
disk   0 "Ys.d88" image 0   # Disk A

# --- timeline ---
wait 90
key  RETURN tap
wait 1.5s
key  SPACE  tap
wait 450
disk select 0 1             # 同じ Ys.d88 の Disk B (image 1) へ
wait 5s                     # ドア開閉の 100ms 窓を見込む
reset warm
```

BootTester からの実行 (予定。disk 引数はスクリプトが内包するため不要):

```bash
cd Packages/EmulatorCore
swift run BootTester --script demo.txt
```

---

## 11. ビルド順 (TDD)

1. ✅ 本仕様の確定。
2. ✅ `ScriptParser` + `ScriptPlayer` を純 Swift で実装 (`Sources/EmulatorCore/Script.swift`,
   `ScriptPlayer.swift`)。ユニットテスト 48 件 (`ScriptParserTests` / `ScriptPlayerTests`)。
3. ✅ BootTester に `--script` を配線 (`swift run BootTester --script file.txt`)。
   相対パスはスクリプト基準で解決。sorpack 等で実ゲーム disk-boot をヘッドレス確認済。
4. ⬜ GUI アプリに UI (読込/再生 → 最後に録画機能)。

### 実装メモ
- `ScriptPlayer` は `Machine` の public API のみを叩く。ディスクパス→バイト列の解決は
  `FileLoader` クロージャに委譲 (純粋・サンドボックス対応)。
- `disk select` / `disk swap` で占有ドライブを差し替えると、`SubSystem` のドア開閉窓
  (~100ms) を経てコミットされる。これは DISK.ROM ありの非 legacy 動作でのみ完了する
  (ROM 無しの裸 Machine では sub-CPU が駆動されないため未コミットのまま)。
- `reset` は `Machine.reset()` が clock8MHz を true に戻すため、スクリプトで `clock` を
  明示していればその値を再適用する (dipSw1/2 は reset 後も保持される)。
- ROM/ディスク起動 (DIPSW2 bit3) はドライブ0の状態から確定するが、確定は **最初に
  時間が進むフレーム** で行う。`wait 0` では確定しないので、`wait` の後に `disk` を
  マウントしても起動モードが固定されない。

### 既知の設計負債 (手順4: アプリ統合時に解消)
- **DIPSW2 bit3 自動確定が三重実装**: ドライブ0の有無から起動ストラップを決める同一
  ロジックが `EmulatorViewModel`(アプリ reset)・`BootTester`(セーブステート reset 経路)・
  `ScriptPlayer.finalizeSetupIfNeeded` の 3 箇所にある。アプリが `ScriptPlayer` を
  統合する際、reset 直後にアプリ側と Player 側で二重確定する恐れがある。`Machine` 等に
  共有ヘルパを 1 本作って 3 箇所から呼ぶ形に寄せること。

---

## 付録 A. キー名リファレンス

`key` 動詞で使える名前 (大文字小文字不問)。これは BootTester の
`BOOTTEST_KEY_EVENTS` と共通のテーブルを使う。

| カテゴリ | 名前 |
|----------|------|
| リターン | `return` (=`enter`) |
| 制御 | `space` `esc` (=`escape`) `stop` `tab` `help` `copy` |
| 修飾 | `shift` `ctrl` `grph` `kana` |
| 矢印 | `up` `down` `left` `right` |
| ファンクション | `f1`〜`f10` |
| 数字 | `0`〜`9` |
| 英字 | `a`〜`z` |
| 記号 | `at` `leftbracket` `rightbracket` `yen` `caret` `minus` `colon` `semicolon` `comma` `period` `slash` `underscore` |
| テンキー | `kp0`〜`kp9` `kpreturn` (=`kpenter`) `kpplus` `kpminus` `kpmultiply` `kpdivide` `kpequal` `kpcomma` `kpperiod` |
| 編集 | `clr` `del` `bs` `ins` `del2` `capslock` |
| ページ | `rollup` `rolldown` |
| 変換 | `henkan` `kettei` `pc` `zenkaku` |

上記以外は **`row-bit` 表記** (例 `2-1` = row 0x02 bit 1 = A) で任意のキーを直接指定可能
(row は 16 進 `0xNN` または 10 進)。
