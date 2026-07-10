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
├── SRVGGNet_x2.pth        source-of-truth — Balanced (self-trained)   [LFS]
├── PROVENANCE.md          this file
└── onnx/                  shared cross-platform inference artifacts
    ├── SRVGGNet_x2_lite.onnx   Fast      (from SRVGGNet_x2_lite.pth)   [LFS]
    ├── SRVGGNet_x2.onnx        Balanced  (from SRVGGNet_x2.pth)        [LFS]
    └── RealESRGAN_x2.onnx      Quality   (regenerable; public weights) [LFS]
```

macOS uses the CoreML `.mlmodelc`; Windows (and a future Linux shell) use
`models/onnx/`. The `.pth → CoreML` and `.pth → ONNX` paths are two exports of the
*same* weights.

> **Which CoreML model does macOS load?** Only the bundled `Bubilator88/Resources/`
> copy. (An external `~/Library/Application Support/Bubilator88/Models/` override
> lookup used to run first, but was removed — a stale override there silently shadowed
> the bundle and diverged from the Windows ONNX. The bundled Balanced `.mlmodelc` was
> regenerated from `pc88_final` so bundle == ONNX; see below.)

## Model architectures

All are x2 super-resolution: 640×400 → 1280×800, RGB, input/output float[0,1] CHW.
The skip-connection upsample mode is NOT stored in the checkpoint — it is pinned in
the converter (`scripts/convert_srvggnet_onnx.py`'s `MODELS` registry).

| Filter   | Network          | num_feat | num_conv | Skip mode | Params  | Source |
|----------|------------------|----------|----------|-----------|---------|--------|
| Fast     | SRVGGNetCompact  | 32       | 12       | bilinear  | 115,756 | self-distilled |
| Balanced | SRVGGNetCompact  | 64       | 16       | bilinear  | 600,652 | self-distilled |
| Quality  | RRDBNet (23 blk) | 64       | —        | (n/a)     | ~16.7 M | Real-ESRGAN x2plus (public) |

`num_feat`/`num_conv` are **inferred from the checkpoint weight shapes**
(`convert_srvggnet_onnx.infer_arch`) — they are not stored anywhere else, so never
hard-code them.

## Origin of each source-of-truth

Both self-trained models are the **final** checkpoints of the April knowledge-
distillation run on the external drive (`/Volumes/CrucialX6/temp/training/`), with a
bilinear skip:

- **Fast** — `SRVGGNet_x2_lite.pth` = `SRVGGNet_x2_pc88_lite_final.pth`. Reproduces the
  bundled `SRVGGNet_x2_lite.mlmodelc` to max|diff| 0.0014.
- **Balanced** — `SRVGGNet_x2.pth` = `SRVGGNet_x2_pc88_final.pth`. The bundled
  `SRVGGNet_x2.mlmodelc` was **regenerated from this checkpoint**
  (`scripts/convert_srvggnet_coreml.py`) so bundle == ONNX; max|diff| 0.0024.
- **Quality** — Real-ESRGAN x2plus public weights (RRDBNet); nothing self-trained.

The bundled `Bubilator88/Resources/SRVGGNet_x2.mlmodelc` had previously been a stale
earlier model (differing from `pc88_final` by ~1.07) that only the `Models/` override
was masking; regenerating it from `pc88_final` and removing the override lookup put
macOS and Windows on the same weights. To regenerate a bundled CoreML model from a
checkpoint:

```bash
python scripts/convert_srvggnet_coreml.py \
    --checkpoint models/SRVGGNet_x2.pth \
    --out-mlmodelc Bubilator88/Resources/SRVGGNet_x2.mlmodelc
```

`scripts/recover_srvggnet_from_mlmodelc.py` (reconstructs a `.pth` from a compiled
`.mlmodelc`'s MIL + weight blob) remains a useful recovery tool, but is not needed for
the shipped pipeline.

## Weight conditioning (defensive)

`convert_srvggnet_onnx.py` runs `equalize_activations()` before export: it rescales
each conv via PReLU positive-homogeneity (`PReLU(a·x)=a·PReLU(x)`, a>0) so
intermediate activations stay ~O(1) **without changing the output** (bit-for-bit
equivalent, fp32 rounding only). Both shipped checkpoints are already well-scaled
(max|weight| < 1), so it is effectively a no-op — kept only as insurance against a
future ill-conditioned checkpoint under reduced-precision (fp16) execution.

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

Both shipped checkpoints use `train_srvggnet.py`'s `SRVGGNetCompact` with its default
**bilinear** skip.

Training data + intermediate checkpoints live on the external drive (not committed —
too large): `/Volumes/CrucialX6/temp/{screenshots_filtered,targets,training}`.

## Regeneration

Requires a Python env with `torch` (+ `onnx`, `onnxruntime` for ONNX;
`coremltools` for CoreML/verification). The training venv used was
`/Volumes/CrucialX6/temp/venv`.

```bash
# ONNX (Windows/Linux) — Fast + Balanced, from the committed .pth (skip modes pinned):
python scripts/convert_srvggnet_onnx.py              # → models/onnx/SRVGGNet_x2*.onnx

# ONNX — Quality (downloads public weights):
python scripts/convert_realesrgan_onnx.py            # → models/onnx/RealESRGAN_x2.onnx

# (tool) Recover a .pth from a compiled .mlmodelc's MIL + weight blob — not used by
# the shipped pipeline, but kept for reconstructing a lost source-of-truth:
python scripts/recover_srvggnet_from_mlmodelc.py \
    --mlmodelc <path>.mlmodelc --output <out>.pth
```

## Verification (macOS ↔ Windows parity)

`scripts/verify_onnx_coreml.py` feeds one random image through both the ONNX and the
CoreML form and reports the max/mean pixel diff. Passing (diff within the float16
budget) is what guarantees the two shells look identical. Verify against the bundled
`Bubilator88/Resources/*.mlmodelc` (the only CoreML model macOS loads):

```bash
python scripts/verify_onnx_coreml.py \
    --onnx   models/onnx/SRVGGNet_x2.onnx \
    --coreml Bubilator88/Resources/SRVGGNet_x2.mlmodelc
```

Reference results (seed 0), ONNX vs the bundled `.mlmodelc`:

| Filter   | max\|diff\| |
|----------|-------------|
| Fast     | 0.00142     |
| Balanced | 0.00236     |
| Quality  | 0.00151     |

All under ~1/255 — pure float16 rounding.
