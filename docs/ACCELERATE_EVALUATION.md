# Accelerate.framework の適用可能性 — 調査結果

調査日: 2026-08-05 / 計測機: Apple M4

「[Accelerate](https://developer.apple.com/documentation/accelerate) の使い所は
あるか」を、候補の洗い出し → マイクロベンチ実測 → 実機の律速確認、の順で調べた
記録。ベンチのソースは `scripts/bench_accelerate.swift`。

## 結論

**現時点では出番なし。** 既に `Bubilator88/Audio/SpectrumAnalyzer.swift` が vDSP を
使っているが、それ以上に導入する価値のある箇所は見つからなかった。

定量的に唯一意味のあった候補（AI アップスケールのテンソル → BGRA 変換）は、
単体では **9.7 倍速く** なるものの、実機では推論そのものが ANE で飽和しており、
全体の 1.4〜7.1% にしか効かない。

将来 AI モデルが軽量化して推論が 10 ms を切るようなことがあれば、下記
「候補 A」を再評価する価値が出てくる。

## 候補 A: MLMultiArray (CHW planar float) → BGRA8888

`Bubilator88/Rendering/AIUpscaler.swift` の `processMultiArrayOutput`。
出力テンソルを 1 ピクセルずつ `min(255, max(0, Int(v * 255.0 + 0.5)))` で
変換している。2x モデルなので 1280x800 x 3ch をスカラーで回す。

### 実測 (1280x800、50 回の平均)

| | 現行スカラー | vImage | 倍率 |
|---|---|---|---|
| Float32 | 2.36 ms | **0.24 ms** | 9.7x |
| Float16 | 2.42 ms | **0.50 ms** | 4.8x |

`kvImageDoNotTile` を外して vImage の内部マルチスレッドを許可すると F32 が
0.21 ms、F16 が 0.24 ms。ただし元々バックグラウンドキューで動くので、
スレッドプールを持ち込む価値は薄い。

### 置き換えの手順

CHW planar なので、各チャネルをそのまま `vImage_Buffer` として見られる
(`strides[3] == 1` であることだけ実行時に確認が要る。`strides[2]` は
`rowBytes` として渡せる)。

1. Float32 → `vImageConvert_PlanarFtoPlanar8(&src, &dst8, 1.0, 0.0, flags)`
   — `maxFloat`/`minFloat` がスケーリングとクランプを兼ねる
2. Float16 → `vImageConvert_Planar16FtoPlanar8` (こちらは [0,1] → [0,255] 固定)
3. 3 プレーンの合成 → `vImageConvert_Planar8toARGB8888` に **B, G, R, α の順**で
   渡すと BGRA バイト列になる。α は 255 で埋めた定数プレーンを一度作って使い回す

### 出力の同一性

**全 4,096,000 バイトが完全一致。** しかも入力レンジを `-0.2 ... 1.2` に広げた
状態でも一致する。超解像モデルの出力は [0,1] をはみ出すことがあるため、
現行コードの明示的なクランプと vImage 側の飽和挙動が食い違わないかを確認する
意図で範囲外まで検証した。丸め差もゼロなので、絵が変わる心配はない。

## 候補 B: RGBA → BGRA スウィズル — **不採用**

`AIUpscaler.swift` の `submitFrame` と `VideoRecorder.swift` の `writeFrame` に
同じ手書きループがある。`vImagePermuteChannels_ARGB8888(map: [2,1,0,3])` で
置き換えられるが、実測すると **遅くなる**。

| | 640x400 |
|---|---|
| 現行スカラー | 0.020 ms |
| vImage | 0.031 ms |

640x400 は完全にキャッシュに乗るサイズでスカラー版が既に 0.02 ms しかなく、
そこへ α を 0xFF で潰すための 2 パス目 (`vImageOverwriteChannelsWithScalar_ARGB8888`)
を足しているのが効いている。**両箇所とも現状維持が正解。**

## 検討したが見送った箇所

### ScreenRenderer のビットプレーン展開 — 型が合わない

`Packages/EmulatorCore/Sources/EmulatorCore/ScreenRenderer.swift` の
`renderColorScanline` / `renderAttributeGraph200` / `renderAttributeGraph400`。
毎フレーム必ず通る本命の重い経路だが、8bit から 1 ビットずつ抜いてパレットを
引く **bit gather** なので vDSP/vImage には乗らない。

速くしたいなら別の手段になる:
- 1 バイト → 8 ピクセル分の `UInt64` を返す 256 エントリの LUT を引く
- あるいは展開自体を Metal シェーダ側に押し込む

なお同ファイルの背景フィル (`for screenY in coveredLines..<screenHeight`) は
3 バイトずつ書いているだけなので `memset_pattern4` か `UInt32` ストアで済む。
これは未計測。該当行はテキスト行数 < 画面高のときだけなので実効ゲインは小さい。

### AudioPostProcessor のリバーブ — リスクが見合わない

`Packages/EmulatorCore/Sources/FMSynthesis/AudioPostProcessor.swift` の
comb/allpass と 1 極 LPF。サンプル逐次のフィードバックでそもそもベクトル化
しづらいうえ、

- `Packages/EmulatorCore/Sources` 配下なので `scripts/regression_compare.py` が必要
- vDSP は浮動小数の演算順序を変える。golden 値でビット一致を固定している
  DSP テストと真っ向から衝突する

44.1kHz ぶんの処理量しかないので、リスクだけ増えてリターンがない。

### AudioOutput の drain 系 — Accelerate の話ではない

`Bubilator88/Audio/AudioOutput.swift` の `drainStereoSamples` /
`drainSpatialSamples` は剰余ループで 1 サンプルずつリングバッファに書いている。
遅いのは確かだが、これは **2 チャンク memcpy に書き直す話**であって Accelerate
ではない (デインターリーブ部分だけは `vDSP_ctoz` が使える)。絶対量が小さく
優先度は低い。

## 実機での律速 — なぜ候補 A が効かないか

`EmulatorMetalView.swift` の FPS 計測は、AI アップスケール有効時には描画
フレーム数ではなく `upscaler.completedCount` の増加レート、つまり
**1 秒あたりの推論完了回数**に切り替わる。`completedCount` は
`processMultiArrayOutput` の末尾で増えるので、表示 FPS の逆数が
「推論 + 変換ループ」1 サイクルの実時間になる。

Apple M4 での実測:

| モデル | 実体 | FPS | 1 サイクル | 変換の割合 | 修正後の予測 |
|---|---|---|---|---|---|
| AI Upscale (Fast) | SRVGGNet_x2_lite | 30 | 33.3 ms | 7.1% | 約 32.1 fps |
| AI Upscale (Balanced) | SRVGGNet_x2 | 15 | 66.7 ms | 3.5% | 約 15.5 fps |
| AI Upscale (Quality) | RealESRGAN_x2 | 6 | 166.7 ms | 1.4% | 約 6.1 fps |

さらに `mactop` で観測したところ、**AI アップスケール実行中は ANE の使用率が
急増し、Quality ではほぼ 100%** に張り付く。つまり:

- モデルは既に Neural Engine に載っている。`MLModelConfiguration` の
  compute units を触っても改善しない
- Quality の 6fps は **ANE 律速**。CPU はその間ほぼ遊んでいる
- 変換ループの 2.36 ms は「暇な CPU で」「ANE が止まっている隙間に」実行されて
  いるだけで、律速段には触れない

## AI アップスケールを速くしたい場合の打ち手

Accelerate とは別の話になるが、上の調査で分かったことを記録しておく。
ANE が飽和している以上、レイヤ数か精度を落とすしかない。

1. **推論結果の使い回し** — 画面が変化していないフレームでは推論をスキップする。
   PC-8801 のゲームは静止画面の時間が長いので、VRAM のハッシュ比較で
   「前フレームと同一なら前回のテクスチャを流用」が効くはず。平均 fps ではなく
   体感が変わり、ANE の消費電力も下がる。**費用対効果が最も高い**
2. **量子化** — `ct.optimize.coreml` の palettization や int8 量子化で ANE の
   実行時間を落とす。超解像は量子化耐性が比較的ある部類
3. **モデルの入れ替え** — RealESRGAN のアーキテクチャで 6fps を実用域に持って
   いくのは厳しい。Fast の SRVGGNet_x2_lite が 30fps 出ているので中間を狙う

なお「CoreML の出力を image 型にして CPU 変換を丸ごと消す」案
(`processImageOutput` の経路が既にある) も考えられるが、効果は上表の 1.4〜7.1%
のままで、ANE が張り付いている状況では変換先が GPU に移るだけ。優先度は低い。

## ベンチの再実行

```sh
swiftc -O scripts/bench_accelerate.swift -o /tmp/bench_accelerate
/tmp/bench_accelerate          # vImage を単一スレッド (kvImageDoNotTile)
TILE=1 /tmp/bench_accelerate   # vImage の内部マルチスレッドを許可
```

現行スカラー版と vImage 版の所要時間に加えて、出力バイト列の一致も検証する。

## 関連

- `docs/AI_TRAINING.md` — 超解像モデルの学習
- `docs/AI_WORKFLOW.md` — AI 活用ガイド
- `scripts/convert_realesrgan.py`, `scripts/train_srvggnet.py` — モデル変換・学習
