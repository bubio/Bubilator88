#!/usr/bin/env python3
"""
Convert a SRVGGNet x2 checkpoint (.pth) to a CoreML .mlpackage and compile it to a
.mlmodelc — the macOS bundle form. Mirrors train_srvggnet.py's convert_to_coreml, but
takes an arbitrary checkpoint so the bundled Resources model can be regenerated from
the current source-of-truth.

Use this to keep macOS (bundled CoreML) and Windows/Linux (ONNX) on the SAME weights.
Both are exported from the same models/*.pth (see models/PROVENANCE.md).

Requirements:
    pip install torch coremltools ; and Xcode (xcrun coremlcompiler)

Usage:
    python scripts/convert_srvggnet_coreml.py \
        --checkpoint models/SRVGGNet_x2.pth \
        --out-mlmodelc Bubilator88/Resources/SRVGGNet_x2.mlmodelc
"""

import argparse
import os
import shutil
import subprocess
import tempfile

import torch

# Reuse the exact architecture + helpers from the ONNX converter.
import importlib.util
_spec = importlib.util.spec_from_file_location(
    "convsrv", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "convert_srvggnet_onnx.py"))
_c = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_c)
SRVGGNetCompact = _c.SRVGGNetCompact
infer_arch = _c.infer_arch
unwrap_state = _c.unwrap_state


def convert(checkpoint, out_mlmodelc, skip_mode="bilinear"):
    import coremltools as ct

    print(f"Loading {checkpoint}")
    state = unwrap_state(torch.load(checkpoint, map_location="cpu", weights_only=True))
    num_feat, num_conv = infer_arch(state)
    print(f"  arch: num_feat={num_feat}, num_conv={num_conv}, skip={skip_mode}")
    model = SRVGGNetCompact(num_feat=num_feat, num_conv=num_conv, skip_mode=skip_mode)
    model.load_state_dict(state, strict=True)
    model.eval()

    input_shape = (1, 3, 400, 640)
    example = torch.randn(input_shape)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)

    # Same conversion settings as train_srvggnet.py: image input with the /255 scale
    # baked in, tensor output; the app's AIUpscaler does the float->RGBA8 step.
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="input", shape=input_shape,
                             scale=1.0 / 255.0, bias=[0, 0, 0], color_layout="RGB")],
        outputs=[ct.TensorType(name="output")],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS15,
    )

    with tempfile.TemporaryDirectory() as tmp:
        pkg = os.path.join(tmp, "model.mlpackage")
        mlmodel.save(pkg)
        print(f"  compiling -> {out_mlmodelc}")
        # coremlcompiler names the output <basename-of-input>.mlmodelc in out dir.
        subprocess.run(["xcrun", "coremlcompiler", "compile", pkg, tmp], check=True)
        compiled = os.path.join(tmp, "model.mlmodelc")
        if os.path.isdir(out_mlmodelc):
            shutil.rmtree(out_mlmodelc)
        shutil.copytree(compiled, out_mlmodelc)
    print(f"Done: {out_mlmodelc}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--out-mlmodelc", required=True)
    ap.add_argument("--skip-mode", choices=["bilinear", "nearest"], default="bilinear")
    args = ap.parse_args()
    convert(args.checkpoint, args.out_mlmodelc, args.skip_mode)


if __name__ == "__main__":
    main()
