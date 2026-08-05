# AI Upscale Models — Provenance & Reproduction

The three AI upscale filters ship as compiled CoreML models in
`Bubilator88/Resources/`. This file records where they came from and how to
rebuild them — which matters most for **Fast** and **Balanced**, trained locally
with **no public weights**: without the checkpoints and the converter here, a lost
or damaged `.mlmodelc` could not be reproduced.

## Read this before touching a model

**The skip-connection upsample mode is not stored in the checkpoint.** It is
pinned by the converter, and both shipped models use **bilinear**. Export with the
wrong mode and you get a model that loads, runs, and looks plausible in every log
— it simply reconstructs detail from nearest-neighbour samples and looks worse.

That is not hypothetical. The bundled Balanced model was a `nearest`-skip export
from the initial commit until 2026-08-05, and nothing caught it for over a year
because an external `~/Library/Application Support/Bubilator88/Models/` override
was loaded in preference to the bundle and happened to hold the correct file. When
that directory went away, the defect surfaced as "Balanced looks bad."

Two things came out of that, and both should stay:

- `AIUpscaler` now loads **only** from the app bundle. There is no override path,
  so what ships is what runs.
- A larger student landing *further* from its teacher than a smaller one is a
  reliable smell test. Balanced sat at 14–28/255 from Real-ESRGAN where Fast sat
  at 5–9; after the correct export, Balanced matches Fast's range.

## Files

```
models/
├── SRVGGNet_x2_lite.pth   source-of-truth — Fast     (self-trained)  [LFS]
├── SRVGGNet_x2.pth        source-of-truth — Balanced (self-trained)  [LFS]
└── PROVENANCE.md          this file
```

Quality has no checkpoint here — it is Real-ESRGAN x2plus public weights.

The ONNX forms used by the Windows shell, and the scripts that build and verify
them (`convert_srvggnet_onnx.py`'s ONNX entry point, `convert_realesrgan_onnx.py`,
`verify_onnx_coreml.py`, `recover_srvggnet_from_mlmodelc.py`), live on the
`feature/windows-native-port` branch, which is shelved. The `.pth` files are the
same source-of-truth on both sides, so a CoreML model rebuilt from here stays
consistent with the ONNX built from there.

## Model architectures

All are x2 super-resolution: 640×400 → 1280×800, RGB, input/output float[0,1] CHW.

| Filter   | Network          | num_feat | num_conv | Skip mode | Params  | Source |
|----------|------------------|----------|----------|-----------|---------|--------|
| Fast     | SRVGGNetCompact  | 32       | 12       | bilinear  | 115,756 | self-distilled |
| Balanced | SRVGGNetCompact  | 64       | 16       | bilinear  | 600,652 | self-distilled |
| Quality  | RRDBNet (23 blk) | 64       | —        | (n/a)     | ~16.7 M | Real-ESRGAN x2plus (public) |

`num_feat`/`num_conv` are **inferred from the checkpoint weight shapes**
(`convert_srvggnet_onnx.infer_arch`) — they are not stored anywhere else, so never
hard-code them.

## Origin of each source-of-truth

Both self-trained models are the **final** checkpoints of the April 2026
knowledge-distillation run on the external drive
(`/Volumes/CrucialX6/temp/training/`), with a bilinear skip:

- **Fast** — `SRVGGNet_x2_lite.pth` = `SRVGGNet_x2_pc88_lite_final.pth`
- **Balanced** — `SRVGGNet_x2.pth` = `SRVGGNet_x2_pc88_final.pth`
- **Quality** — Real-ESRGAN x2plus public weights (RRDBNet); nothing self-trained

## Regeneration

Needs a Python env with `torch` + `coremltools`, and Xcode for
`xcrun coremlcompiler`. The training venv was `/Volumes/CrucialX6/temp/venv`.

```bash
python scripts/convert_srvggnet_coreml.py \
    --checkpoint models/SRVGGNet_x2.pth \
    --out-mlmodelc Bubilator88/Resources/SRVGGNet_x2.mlmodelc
```

`--skip-mode` defaults to `bilinear`; there is no reason to pass anything else for
these two checkpoints.

`convert_srvggnet_coreml.py` imports the architecture, `infer_arch` and
`unwrap_state` from `convert_srvggnet_onnx.py`. Both scripts are needed even
though nothing here produces ONNX.

### Verified

Regenerating each model from the checkpoint above and comparing against the
shipped `.mlmodelc` over PC-8801 frames (2026-08-05):

| Filter   | max\|diff\| vs shipped |
|----------|------------------------|
| Fast     | 0.0000 |
| Balanced | 0.0000 |

Bit-exact, not merely within float16 tolerance — the checkpoints and converter in
this repo reproduce exactly what ships.

## Weight conditioning (defensive)

`convert_srvggnet_onnx.py` defines `equalize_activations()`: it rescales each conv
via PReLU positive-homogeneity (`PReLU(a·x) = a·PReLU(x)`, a > 0) so intermediate
activations stay ~O(1) **without changing the output** (bit-for-bit equivalent, fp32
rounding only). Both shipped checkpoints are already well-scaled (max|weight| < 1),
so it is effectively a no-op — kept as insurance against a future ill-conditioned
checkpoint under reduced-precision execution. The CoreML path does not call it.

## How Fast/Balanced were trained (knowledge distillation)

Teacher = Real-ESRGAN x2plus (Quality). Student = SRVGGNetCompact. The student
learns to reproduce the teacher's output on real PC-8801 frames, giving a much
cheaper model tuned to this machine's content.

Data pipeline (scripts, in order — all on the shelved branch):

1. `capture_reference_screenshots.py` — collect native 640×400 PNG frames
2. `filter_screenshots.py` — curate/clean the input set
3. `generate_targets.py` — run Real-ESRGAN over inputs → 1280×800 targets
4. `train_srvggnet.py` — L1 distillation, random 128px crops + h-flip, Adam
   lr 2e-4, cosine anneal, ~1000 epochs

Both shipped checkpoints use `train_srvggnet.py`'s `SRVGGNetCompact` with its
default **bilinear** skip.

Training data and intermediate checkpoints are too large to commit and live on the
external drive: `/Volumes/CrucialX6/temp/{screenshots_filtered,targets,training}`.

## Inference cost (M4, macOS 26.6)

Measured standalone with no contention, so treat these as a floor. Over 98% of the
cost is on the Neural Engine for all three, which is why the app reduces *how often*
it infers rather than trying to make inference itself cheaper.

| Filter   | Inference | Sustains 60 fps |
|----------|-----------|-----------------|
| Fast     | 16.7 ms   | yes |
| Balanced | 41.3 ms   | no (~24 fps) |
| Quality  | 150.2 ms  | no (~6.7 fps) |
