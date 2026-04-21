# Regression Check — デグレチェック

エミュレーション挙動の変更がリグレッションを起こしていないかを、**既知の
ゲーム起動シナリオを pixel 完全一致で比較**して検出する仕組み。

## いつ実行するか

`Packages/EmulatorCore/Sources/` 配下 (CPU / Peripherals / Bus / Machine /
SubSystem / ScreenRenderer / FMSynthesis など) の挙動を変えうる修正を
入れたら、コミット前に実行する。UI / Metal シェーダ / App 層のみ、かつ
エミュレーション挙動に影響が出ないと確信できる場合はスキップ可。迷ったら
走らせる。

## 構成

3 つの成果物が連携する:

| 成果物 | 役割 |
|--------|------|
| `docs/REGRESSION_CHECK_PLAN.md` | シナリオの**仕様書**。各ゲームのブート手順 (DIP SW, クロック, キー入力列, 撮影タイミング) と判定条件を明文化 |
| `scripts/capture_reference_screenshots.py` | プランに沿って BootTester を叩き、参照 PPM を `TEST/SS/` に出力 |
| `scripts/regression_compare.py` | 同じシナリオを再実行し、参照 PPM と pixel 単位で比較 |

**プランは著者が手書きで維持する**。タイミングやキー入力はゲーム側の
挙動に依存するため、自動抽出は不可能。プランを直したらキャプチャ
スクリプトと同期してシナリオ定義を更新する。

## 参照スクリーンショット

出力先は `TEST/SS/` (= プラン中の `/SS/`)。著作物の派生画像のため
**リポジトリには含めない** ( git に追加しない運用)。

環境を移行したり参照を取り直したいときは:

```bash
python3 scripts/capture_reference_screenshots.py
```

プランに変更が入った場合は、変更シナリオの PPM を `rm` してから再実行
する。既存の PPM は上書きされるが、明示的に削除した方が「撮り直したか」
が見やすい。

## 仮想 RTC (BOOTTEST_VIRTUAL_RTC)

BootTester はフレームを wall-clock より速く回すため、host 時刻基準の
RTC (uPD1990A) は「emulated 時間から見ると止まって見える」現象が起きる。
RTC 経過を条件に画面遷移するゲーム (例: SB2 Music Disk v4) はこれで
初期画面から進まなくなる。

`BOOTTEST_VIRTUAL_RTC=1` を付けると、BootTester は `machine.totalTStates`
からエミュレート秒数を算出して RTC に返す。ゲーム側の時間感覚と一致する
ので、当該ゲームのみ有効化する。対象は `capture_reference_screenshots.py`
の `VIRTUAL_RTC_SCENARIOS` に定義。新たに該当ゲームを追加したときは
ここに名前を足す。

App 本体は real-time 60fps 固定で wall-clock と emulated 時間が一致する
ため、仮想 RTC は不要。**BootTester 専用の補正**であることに注意。

## 一部領域をマスクする比較

ゲームによってはランダム表示でフレーム毎に違う pixel を出す領域がある
(Wizardry のモンスターサムネなど)。`regression_compare.py` はシナリオ
名で判定してマスクを適用する。対象領域はプランに明記し、マスクの
座標は compare スクリプトに定数で持たせる。

追加する場合:
1. プランに「y=A..B をマスク」と明示
2. `regression_compare.py` の該当定数 (`WIZARDRY_MASK_Y_RANGE` など) を
   シナリオ対応で増やす

## 既知の「BootTester 固有」対応

BootTester と App で実装パスが分かれている箇所は、Core の修正が入っても
BootTester 側で参照漏れが起きやすい。過去にハマった例:

| 箇所 | 症状 | 対応 |
|------|------|------|
| `renderTextOverlay` の `attributeGraphMode` 引数 | exective.d88 の選択項目が白抜け | BootTester の `renderCurrentFrame` にも同じ判定式を渡す (commit `8b7ac83d`) |
| 仮想 RTC | SB2 Music Disk v4 が初期画面から進まない | `BOOTTEST_VIRTUAL_RTC` 追加 |

Core (EmulatorCore パッケージ) の描画 / 時間関連 API を変えたときは、
BootTester 側の呼び出しも見直す。

## 他の検査スクリプトとの関係

| スクリプト | 用途 | 粒度 |
|----------|------|------|
| `scripts/regression_compare.py` | デグレ検知 (本ドキュメントの主役) | pixel 完全一致、15 ゲーム |
| `scripts/rom_sweep.py` | 新規タイトルの互換性探索 | ヒューリスティック判定、広範な D88 群 |

`regression_compare.py` が **pixel 一致** で「既に動くものが動いたまま」
を保証し、`rom_sweep.py` は「そもそも起動に到達できたか」を粗く判定する。
役割が異なるので併用する。
