# AI Upscale Models — Provenance & Reproduction

Bubilator88's AI upscale filters share **one source-of-truth per model** across
platforms: a PyTorch checkpoint (`.pth`) from which both the macOS CoreML
(`.mlmodelc`) and the Windows/Linux ONNX (`.onnx`) forms are generated. This file
records everything needed to regenerate the models — especially the **Fast** and
**Balanced** models, which were trained locally and have **no public weights**.

> Every ONNX here is verified to reproduce the *shipped* macOS CoreML model within
> float16 rounding (see "Verification"). That parity is what guarantees macOS and
> Windows look identical.

## Files

```
models/
├── SRVGGNet_x2_lite.pth   source-of-truth — Fast     (self-trained)   [LFS]
├── SRVGGNet_x2.pth        source-of-truth — Balanced (recovered)      [LFS]
├── PROVENANCE.md          this file
└── onnx/                  shared cross-platform inference artifacts
    ├── SRVGGNet_x2_lite.onnx   Fast      (from SRVGGNet_x2_lite.pth)   [LFS]
    ├── SRVGGNet_x2.onnx        Balanced  (from SRVGGNet_x2.pth)        [LFS]
    └── RealESRGAN_x2.onnx      Quality   (regenerable; public weights) [LFS]
```

macOS uses the CoreML `.mlmodelc` bundled under `Bubilator88/Resources/`; Windows
(and a future Linux shell) use `models/onnx/`. The `.pth → CoreML` and `.pth → ONNX`
paths are two exports of the *same* weights.

## Model architectures

All are x2 super-resolution: 640×400 → 1280×800, RGB, input/output float[0,1] CHW.
The **skip-connection upsample mode differs per model** and is NOT stored in the
checkpoint — it is pinned in the converter (`scripts/convert_srvggnet_onnx.py`'s
`MODELS` registry) and auto-detected from the MIL during recovery.

| Filter   | Network          | num_feat | num_conv | Skip mode | Params  | Source |
|----------|------------------|----------|----------|-----------|---------|--------|
| Fast     | SRVGGNetCompact  | 32       | 12       | bilinear  | 115,756 | self-distilled |
| Balanced | SRVGGNetCompact  | 64       | 16       | nearest   | 600,652 | self-distilled |
| Quality  | RRDBNet (23 blk) | 64       | —        | (n/a)     | ~16.7 M | Real-ESRGAN x2plus (public) |

`num_feat`/`num_conv` are **inferred from the checkpoint weight shapes**
(`convert_srvggnet_onnx.infer_arch`) — they are not stored anywhere else, so never
hard-code them.

## Origin of each source-of-truth

- **Fast** — `SRVGGNet_x2_lite.pth` is the training checkpoint
  `SRVGGNet_x2_pc88_lite_final.pth` from the April distillation run (external drive:
  `/Volumes/CrucialX6/temp/training/`). It reproduces the shipped
  `SRVGGNet_x2_lite.mlmodelc` to max|diff| 0.0014.
- **Balanced** — the shipped `SRVGGNet_x2.mlmodelc` was built from an **earlier**
  training run (CoreML class name `SRVGGNet_x2`, converted before the April run) whose
  `.pth` **no longer exists on any disk**. `SRVGGNet_x2.pth` here was **recovered from
  the compiled CoreML model itself** by parsing its MIL graph + fp16 weight blob
  (`scripts/recover_srvggnet_from_mlmodelc.py`), reproducing it to max|diff| 0.0029.
  This is exactly the single-point-of-failure the repo now guards against — the model
  survived only as the compiled artifact.
- **Quality** — Real-ESRGAN x2plus public weights (RRDBNet); nothing self-trained.

## How Fast/Balanced were trained (knowledge distillation)

Teacher = Real-ESRGAN x2plus (Quality). Student = SRVGGNetCompact. The student learns
to reproduce the teacher's output on real PC-8801 frames, giving a much cheaper model
tuned to this machine's content.

Data pipeline (scripts, in order):
1. `scripts/capture_reference_screenshots.py` — collect native 640×400 PNG frames.
2. `scripts/filter_screenshots.py` — curate/clean the input set.
3. `scripts/generate_targets.py` — run Real-ESRGAN over inputs → 1280×800 targets.
4. `scripts/train_srvggnet.py` — L1 distillation, random 128px crops + h-flip,
   Adam lr 2e-4, cosine anneal, ~1000 epochs.

> Note: `train_srvggnet.py`'s `SRVGGNetCompact` uses a **bilinear** skip. The shipped
> Balanced model predates that and used a **nearest** skip; the recovery script and the
> converter registry account for this per model.

Training data + intermediate checkpoints live on the external drive (not committed —
too large): `/Volumes/CrucialX6/temp/{screenshots_filtered,targets,training}`.

## Regeneration

Requires a Python env with `torch` (+ `onnx`, `onnxruntime` for ONNX;
`coremltools` for CoreML/recovery). The training venv used was
`/Volumes/CrucialX6/temp/venv`.

```bash
# ONNX (Windows/Linux) — Fast + Balanced, from the committed .pth (skip modes pinned):
python scripts/convert_srvggnet_onnx.py              # → models/onnx/SRVGGNet_x2*.onnx

# ONNX — Quality (downloads public weights):
python scripts/convert_realesrgan_onnx.py            # → models/onnx/RealESRGAN_x2.onnx

# Recover a lost source-of-truth from a compiled CoreML model (how SRVGGNet_x2.pth
# was reconstructed):
python scripts/recover_srvggnet_from_mlmodelc.py \
    --mlmodelc Bubilator88/Resources/SRVGGNet_x2.mlmodelc --output models/SRVGGNet_x2.pth
```

## Verification (macOS ↔ Windows parity)

`scripts/verify_onnx_coreml.py` feeds one random image through both the ONNX and the
CoreML form and reports the max/mean pixel diff. Passing (diff within the float16
budget) is what guarantees the two shells look identical.

```bash
python scripts/verify_onnx_coreml.py \
    --onnx   models/onnx/SRVGGNet_x2.onnx \
    --coreml Bubilator88/Resources/SRVGGNet_x2.mlmodelc
```

Reference results (seed 0), ONNX vs the **shipped** `.mlmodelc`:

| Filter   | max\|diff\| | mean\|diff\| |
|----------|-------------|--------------|
| Fast     | 0.00142     | 0.000201     |
| Balanced | 0.00289     | 0.000332     |
| Quality  | 0.00151     | 0.000211     |

All under ~1/255 — pure float16 rounding.
