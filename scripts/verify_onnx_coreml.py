#!/usr/bin/env python3
"""
Verify that an ONNX model (Windows/Linux path) and its CoreML counterpart
(macOS path) produce the same upscaled output for the same input.

Both are generated from one source-of-truth .pth (see convert_srvggnet_onnx.py /
convert_realesrgan_onnx.py), so they should agree to within float16 rounding —
this is what guarantees macOS and Windows look identical.

Convention (matches AiUpscaler.cs / AIUpscaler.swift MultiArray path):
  - CoreML input is an ImageType (uint8 RGB image); the /255 scale is baked in.
  - ONNX input is float[0,1] RGB CHW; we divide by 255 here (the host does this).
  - Both outputs are float NCHW [1,3,800,1280].

Requirements:
    pip install onnxruntime coremltools numpy pillow

Usage:
    python scripts/verify_onnx_coreml.py \
        --onnx models/onnx/SRVGGNet_x2.onnx \
        --coreml /Volumes/CrucialX6/temp/training/SRVGGNet_x2_pc88.mlpackage
"""

import argparse
import numpy as np
from PIL import Image

W, H = 640, 400


def run_onnx(path, img_u8):
    import onnxruntime as ort
    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    x = img_u8.astype(np.float32).transpose(2, 0, 1)[None] / 255.0  # 1,3,H,W RGB
    name = sess.get_inputs()[0].name
    return sess.run(None, {name: x})[0]


def run_coreml(path, img_u8):
    import coremltools as ct
    # A compiled .mlmodelc (what the app bundles) loads via CompiledMLModel;
    # a .mlpackage / .mlmodel loads via MLModel.
    if str(path).rstrip("/").endswith(".mlmodelc"):
        model = ct.models.CompiledMLModel(path)
    else:
        model = ct.models.MLModel(path)
    pil = Image.fromarray(img_u8, mode="RGB")
    out = model.predict({"input": pil})
    return np.asarray(out["output"], dtype=np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--onnx", required=True)
    ap.add_argument("--coreml", required=True)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--tol", type=float, default=0.05,
                    help="Max abs diff allowed (float16 rounding budget)")
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    img = rng.integers(0, 256, size=(H, W, 3), dtype=np.uint8)

    o = run_onnx(args.onnx, img).astype(np.float32)
    c = run_coreml(args.coreml, img).astype(np.float32)

    if o.shape != c.shape:
        print(f"SHAPE MISMATCH: onnx {o.shape} vs coreml {c.shape}")
        raise SystemExit(1)

    diff = np.abs(o - c)
    print(f"onnx   {args.onnx}")
    print(f"coreml {args.coreml}")
    print(f"  shape={o.shape}  max|diff|={diff.max():.5f}  "
          f"mean|diff|={diff.mean():.6f}")
    if diff.max() <= args.tol:
        print(f"  PASS (within tol {args.tol})")
    else:
        print(f"  FAIL (exceeds tol {args.tol})")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
