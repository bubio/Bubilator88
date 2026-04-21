# AI Upscaling Model Training Pipeline

PC-8801 画面に特化した軽量超解像モデル (SRVGGNet x2) の知識蒸留学習パイプライン。

---

## 概要

RealESRGAN (高品質・重い) の出力を正解データとして、SRVGGNet (軽量・高速) に知識蒸留する。
PC-8801 特有のディザリングパターン・8色パレット・640x400 解像度に最適化。

```
入力: 640x400 ネイティブ → SRVGGNet x2 → 1280x800 出力
正解: 640x400 ネイティブ → RealESRGAN x2 → 1280x800 正解
Loss: L1(SRVGGNet出力, RealESRGAN出力)
```

## 環境変数 (本文の例で使用)

以降の bash 例は次の 2 つの環境変数を前提にする。自分の環境に合わせて
書き換えること。

```bash
export ARCHIVES=/path/to/rom-archives    # 入力: cab/lzh/zip アーカイブ
export WORK=/path/to/workspace           # 作業領域: 展開先・中間生成物・モデル出力
```

## パイプライン全体像

```
Stage 1: アーカイブ展開      scripts/extract_archives.sh
Stage 2: スクリーンショット収集  scripts/collect_screenshots.sh
Stage 3: フィルタリング        scripts/filter_screenshots.py
Stage 4: 正解データ生成        scripts/generate_targets.py
Stage 5: 学習                scripts/train_srvggnet.py
Stage 6: CoreML変換・インストール (手動)
```

---

## Stage 1: アーカイブ展開

D88 ディスクイメージを cab/lzh/zip アーカイブから一括展開。

```bash
bash scripts/extract_archives.sh $ARCHIVES $WORK/d88
```

- bsdtar (CP932 charset 対応) を優先、失敗時に unar にフォールバック
- ネストされたアーカイブも再帰展開
- 初回実行結果: 1140 アーカイブ → 1984 D88 ファイル

---

## Stage 2: スクリーンショット収集

BootTester でゲームを自動実行し、一定間隔でスクリーンショットを PPM 形式で保存。

```bash
bash scripts/collect_screenshots.sh $WORK/d88 $WORK/screenshots
```

### 環境変数

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `PARALLEL` | 4 | 並列実行数 |
| `SKIP_EXISTING` | 1 | 既存ファイルをスキップ |
| `KEY_PATTERN` | (なし) | キー入力パターン (return/space/random) |

### BootTester 拡張パラメータ

| 変数 | 説明 |
|------|------|
| `BOOTTEST_SCREENSHOT_DIR` | スクリーンショット出力ディレクトリ |
| `BOOTTEST_SCREENSHOT_INTERVAL` | N フレームごとに撮影 |
| `BOOTTEST_SCREENSHOT_BASENAME` | ファイル名のプレフィックス |

### デフォルト設定

- 1800 フレーム (30 秒)、300 フレーム間隔 → 1 ゲームあたり最大 5 枚
- タイムアウト 60 秒、失敗ログは `failed.log` / `timeout.log`
- 初回実行結果: 1975 ゲーム → 9865 PPM

### 多様性を増やすキー入力パターン (Stage 2+)

```bash
# RETURN 連打 (メニュー突破用)
KEY_PATTERN=return bash scripts/collect_screenshots.sh ...

# SPACE 連打
KEY_PATTERN=space bash scripts/collect_screenshots.sh ...

# ランダム (Y→RETURN→SPACE→RETURN)
KEY_PATTERN=random bash scripts/collect_screenshots.sh ...
```

---

## Stage 3: フィルタリング

黒画面・同一ゲーム内の重複画像を除去し、PPM → PNG 変換。

```bash
python scripts/filter_screenshots.py \
  --input $WORK/screenshots \
  --output $WORK/screenshots_filtered
```

- 全ピクセル同色の画像を除去
- 同一ゲーム内でピクセル完全一致の重複を除去
- sips で PPM → PNG 変換
- 初回実行結果: 9865 → 4699 枚

---

## Stage 4: 正解データ生成

RealESRGAN (RRDBNet) で 640x400 → 1280x800 にアップスケール。

```bash
source $WORK/venv/bin/activate
python scripts/generate_targets.py \
  --input $WORK/screenshots_filtered \
  --output $WORK/targets \
  --weights /path/to/RealESRGAN_x2plus.pth
```

- RRDBNet アーキテクチャ (Real-ESRGAN x2plus と同一)
- MPS (Apple GPU) または CPU で実行
- 出力: 入力と同名の 1280x800 PNG

### RealESRGAN 重みファイル

`RealESRGAN_x2plus.pth` が必要。公式リポジトリからダウンロード:
https://github.com/xinntao/Real-ESRGAN

---

## Stage 5: 学習

SRVGGNetCompact の知識蒸留学習。

```bash
source $WORK/venv/bin/activate
python scripts/train_srvggnet.py \
  --input $WORK/screenshots_filtered \
  --target $WORK/targets \
  --output $WORK/training \
  --patch_size 64 --batch_size 32 --epochs 1000 --lr 2e-4
```

### モデルアーキテクチャ

SRVGGNetCompact: VGG スタイルの軽量超解像ネットワーク。

| パラメータ | 値 |
|-----------|-----|
| Feature channels | 64 |
| Body conv layers | 16 |
| Total parameters | 600,652 |
| Upscale factor | 2x |
| Activation | PReLU |

### 学習設定

| 設定 | 値 |
|------|-----|
| Loss | L1 |
| Optimizer | Adam |
| Learning rate | 2e-4 → cosine annealing → 2e-6 |
| Patch size | 64x64 (ランダムクロップ) |
| Batch size | 32 |
| Augmentation | ランダム水平反転 |
| Device | auto (MPS > CUDA > CPU) |

### 出力ファイル

| ファイル | 説明 |
|---------|------|
| `SRVGGNet_x2_pc88_best.pth` | ベスト Loss の重み |
| `SRVGGNet_x2_pc88_e{N}.pth` | 50 エポックごとのチェックポイント |
| `SRVGGNet_x2_pc88_final.pth` | 最終エポックの重み |
| `SRVGGNet_x2_pc88.mlpackage` | CoreML モデル (未コンパイル) |

### 初回学習結果 (2026-04-05)

- データ: 4,699 ペア
- 1000 エポック、MPS (Apple GPU)、約 10 時間
- Best loss: 0.009041
- Bilinear 比 平均 PSNR +7.72 dB

---

## Stage 6: CoreML 変換・インストール

学習完了時に自動で mlpackage が生成される。手動でコンパイル・インストール:

```bash
# コンパイル
cd $WORK/training
xcrun coremlcompiler compile SRVGGNet_x2_pc88.mlpackage .

# インストール (Models/ に置くとバンドル版より優先)
cp -r SRVGGNet_x2_pc88.mlmodelc \
  ~/Library/Application\ Support/Bubilator88/Models/SRVGGNet_x2.mlmodelc
```

### バンドル版を置き換える場合

```bash
cp -r SRVGGNet_x2_pc88.mlmodelc \
  /path/to/Bubilator88/Resources/SRVGGNet_x2.mlmodelc
```

---

## Python 環境

```bash
python3 -m venv $WORK/venv
source $WORK/venv/bin/activate
pip install torch torchvision pillow coremltools numpy
```

---

## アプリへの組み込み — モード3段構成

実装されている AI フィルタの3モード:

| モード | モデル | チャネル × 層 | パラメータ数 | 用途 |
|--------|--------|--------------|--------------|------|
| **AI Upscale (Fast)** | `SRVGGNet_x2_lite` | 32 × 12 | 約 11.6万 | 60fps重視・軽量端末 |
| **AI Upscale (Balanced)** | `SRVGGNet_x2` | 64 × 16 | 約 60万 | 標準。画質と速度のバランス |
| **AI Upscale (Quality)** | `RealESRGAN_x2` | RRDB系 | 約 1670万 | 静的画面・スクリーンショット用 |

`Bubilator88/Resources/` に mlmodelc を配置することで自動的にバンドルされる。
ファイル名と enum の対応は `EmulatorViewModel.VideoFilter.aiModelName` を参照。

### 学習コマンド (lite 版)

```bash
source $WORK/venv/bin/activate
python scripts/train_srvggnet.py \
  --input $WORK/screenshots_filtered \
  --target $WORK/targets \
  --output $WORK/training \
  --num_feat 32 --num_conv 12 \
  --model_name SRVGGNet_x2_pc88_lite \
  --patch_size 64 --batch_size 32 --epochs 1000 --lr 2e-4
```

### 視覚比較スクリプト

学習したモデルを Real-ESRGAN 正解と並べて比較する:

```bash
python scripts/compare_srvggnet.py \
  --input $WORK/screenshots_filtered \
  --target $WORK/targets \
  --weights $WORK/training/SRVGGNet_x2_pc88_lite_best.pth \
  --num_feat 32 --num_conv 12 \
  --output $WORK/lite_comparison \
  --samples 6
```

`--names file1 file2 ...` で特定ファイルを指定可能。

---

## 今後の改善案

### 学習データ・損失関数

1. **データ増量**: キー入力パターン (Stage 2) で 2-3 倍に増やす
2. **Perceptual Loss**: VGG 特徴量空間での Loss を追加 (エッジ・質感向上)
3. **SSIM Loss**: 構造的類似度を Loss に組み込む
4. **より大きなパッチサイズ**: GPU メモリが許せば 128x128 で文脈を広げる
5. **Progressive training**: 低解像度から段階的にパッチサイズを拡大

### 軽量モデルの「補正過剰」問題と対策

一枚絵では理想的でも、**小さいキャラクターが動くゲーム画面**では SRVGGNet
が 1ピクセル幅の輪郭線やアンチエイリアスのないスプライトを「ノイズ」と見な
して滑らかに塗り替えてしまうことがある。オリジナルの明瞭さを損なわず、AI
の補完をマイルドにかける方向の検討。

| 案 | 内容 | 工数 | 期待効果 |
|----|------|------|---------|
| **A. さらに縮小** | 16ch × 8layers (~15K params) | 学習のみ | モデル容量が小さいぶん補正が穏やかになる傾向 |
| **B. Skip強化** | `forward()` の `base + out` を `base + α * out` (α<1) に変更 | コード1行+再学習 | オリジナル寄りに線形ブレンド。α=0.5 で中間、0.3 でほぼオリジナル |
| **C. パッチサイズ拡大** | 学習時 patch_size=128 で文脈を広く見せる | 学習設定変更 | 動くキャラの輪郭の文脈を学習しやすい |
| **D. 動的シーン追加** | キー操作・ランダム入力でアニメ中フレームを多く収集 | Stage 2 再実行 | 静止画偏重を緩和 |
| **E. 推論時ブレンド** | アプリ側で `output = (1-β)*nearest + β*ai` | Metal シェーダ追加 | ユーザがリアルタイムに強度調整可。再学習不要 |

**最小工数の試行順**: B案 (再学習1回) → E案 (シェーダ実装) → A案 (より小さいモデル学習)

### 用途別モデルの分離

将来、用途別に複数のモデルを持つ案:
- **Gameplay モデル**: 動的シーン中心、補正控えめ (B/C/D の複合)
- **Cutscene モデル**: 静的画面用、現在の Balanced/Quality 寄り
- アプリ側でディスク種別やフレーム差分から自動切替も可能

## データの所在

初回学習時のデータ:

```
$WORK/
├── d88/                          展開済み D88 (1984 files)
├── screenshots/                  生 PPM スクリーンショット (9865 files)
├── screenshots_filtered/         フィルタ済み PNG (4699 files)
├── targets/                      RealESRGAN 正解 PNG (4699 files)
├── training/                     学習出力
│   ├── SRVGGNet_x2_pc88_best.pth
│   ├── SRVGGNet_x2_pc88_final.pth
│   ├── SRVGGNet_x2_pc88.mlpackage
│   ├── SRVGGNet_x2_pc88.mlmodelc
│   └── train.log
└── venv/                         Python 仮想環境
```
