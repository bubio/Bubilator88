# ROM Sweep — 互換性チェック

`scripts/rom_sweep.py` は、手持ちの D88 ライブラリ全体 (1240本規模) を
BootTester で一括起動し、30秒 / 60秒時点のスクリーンショットを画像分類で
ラベリングするためのツール。**互換性検証** — 「どのタイトルが動き、どれが
動かないか」を俯瞰するためのもの。

デグレ検知は `regression_compare.py` (`REGRESSION_CHECK.md`) が担当する。
`rom_sweep.py` は**未知タイトルの互換性スクリーニング**、
`regression_compare.py` は**既知シナリオの pixel 完全一致検査**、と役割が
違う。

## 前提

1. BootTester をビルド済みであること。

   ```bash
   cd Packages/EmulatorCore
   swift build -c release --product BootTester
   ```

2. `~/Library/Application Support/Bubilator88/` に必要な ROM (N88.ROM,
   DISK.ROM など) が配置されていること。

3. ROM コレクションディレクトリが参照可能であること。具体パスは
   `scripts/rom_sweep.py` の `ROM_DIR` / `OUT_BASE` 定数で設定する。

## 使い方

```bash
# ランダム 10 本で実験 (デフォルト)
python3 scripts/rom_sweep.py --sample 10 --seed 42

# 全ディスク対象 (並列4 で約1時間強 / 1132本)
python3 scripts/rom_sweep.py --all --workers 4
```

### オプション

| Flag | Default | 説明 |
|------|---------|------|
| `--sample N` | 10 | ランダム抽出する本数 |
| `--seed S` | 42 | 乱数シード (再現性確保) |
| `--all` | off | 全 D88 を対象にする |
| `--workers N` | 4 | 並列数。BootTester 1本あたり CPU 1コア消費 |

### 固定値 (スクリプト内定数)

- 入力ディレクトリ: `ROM_DIR` (`*.d88` を再帰探索)
- 出力先: `OUT_BASE/rom_sweep_<YYYYMMDD_HHMMSS>/`
- ターボ倍率: `TURBO=8`
- CPU クロック: `CLOCK_4MHZ=1` (4MHz 固定)
- サンプル点: 30秒 / 60秒 (エミュレート時間)

### TURBO と FRAMES の関係

`BOOTTEST_TURBO=8` は「論理フレーム1回あたり内部で8フレーム回す」動作。
したがって `BOOTTEST_FRAMES=F` が回す実エミュレートフレーム数は `F × 8`。

- 30秒相当 = `30 × 60 / 8 = 225` frames
- 60秒相当 = `60 × 60 / 8 = 450` frames

BootTester には「1回の run 全体で実時間 30秒超えたら abort」のセーフティが
組み込まれているため、TURBO なしで FRAMES=3600 などを指定すると ABORT されて
スクリーンショットが書かれない。ターボ8倍前提の FRAMES 値に合わせること。

## 出力構成

```
OUT_BASE/rom_sweep_20260414_190030/
├── report.json              全エントリの metrics / verdicts
├── ng_disks.txt             両ショット NG だった D88 のフルパス一覧
└── <ゲーム名>/
    ├── 30s.ppm              30秒時点スクリーンショット (640×400, P6)
    ├── 30s.log              BootTester stdout/stderr
    ├── 60s.ppm
    └── 60s.log
```

`report.json` の各エントリ:

```json
{
  "path": "<ROM_DIR>/Ys.d88",
  "name": "Ys.d88",
  "verdicts": ["ok", "ok"],
  "ng": false,
  "shots": {
    "30s": {
      "verdict": "ok",
      "mean_rgb": [38.0, 35.7, 90.2],
      "black_ratio": 0.12,
      "blue_ratio": 0.41,
      "white_ratio": 0.03,
      "palette": 8,
      "wall_sec": 12.3
    },
    "60s": { ... }
  }
}
```

## 判定ロジック (classify)

BootTester ログ中の `Text VRAM rows:` セクションと PPM 画素の両方を見る:

| verdict | 条件 |
|---------|------|
| `basic` | TEXT VRAM に `Bytes free` を含む、または独立した `Ok` / `Ok.` 行がある |
| `black` | 非黒画素 < 200 かつ 平均輝度 < 0.5 (= 実質何も表示されていない) |
| `blue`  | 青画素比率 > 0.55 かつ `meanB > meanR+30` かつ白画素比率 < 0.10 |
| `ok`    | 上記いずれでもない |

### basic 判定の考え方

PC-88 の Disk BASIC はブート時に `How many files(0-15)?` で入力待ちになるのが
正しい挙動 (= OK)。ゲーム/アプリは自動で応答して独自画面に遷移すべきだが、
応答できず BASIC の `Ok` プロンプトに戻った場合はロード失敗 (= NG)。

- **OK** 側のマーカー: `How many files(0-15)?` が単独で残り、`Bytes free` は
  まだ表示されていない (= 起動バナーが描画される前のプロンプト段階)
- **NG** 側のマーカー: `NEC N-88 BASIC Version ...` / `XXXXX Bytes free` /
  `Ok` / `Ok.` のいずれかが出現 (= BASIC 完全起動後のアイドル状態)

判定キーとして `Bytes free` と単独 `Ok` 行を採用。`How many files` 単体は
OK 扱いにするため条件に含めない。

### black 判定

「画面が完全に凍結・未描画」のケースのみを拾う (全画素を numpy で処理)。
暗い背景にテキスト/星/キャラが少しでもあれば `ok`。

### その他の verdict

- `missing` — BootTester がスクリーンショットを書かずに abort
- `timeout` — subprocess が 180秒以内に終了しなかった

**NG ディスク判定**: 30秒ショットと 60秒ショットの verdict が両方とも
`{black, blue, basic, missing, timeout}` のいずれかだったもの。

`ok` の誤検出 / 見逃しが発生しうる閾値なので、過信せず `report.json` と
実スクショの目視を併用すること。

## 過去の実験

2026-04-14 `--sample 10 --seed 42`: 10本中 4本 NG (全て black)。NG 4本は
黒画のまま停止。OK 6本はタイトル / デモ画面に到達を目視確認。

全数掃引は互換性向上後に実施予定。現状 (2026-04-14) は NG が多すぎて
フィルタとして有効に機能しない段階。
