#!/usr/bin/env python3
"""
Recover a SRVGGNetCompact PyTorch checkpoint from a *compiled* CoreML model
(`.mlmodelc`) by parsing its MIL program + weight blob.

Why this exists: the shipped macOS Balanced model
(`Bubilator88/Resources/SRVGGNet_x2.mlmodelc`) was built from a training run whose
`.pth` is lost — the compiled model is the ONLY surviving copy of those weights.
This script reads them back into a `.pth`, restoring a source-of-truth from which
BOTH the ONNX (Windows/Linux) and, if ever needed, a fresh CoreML model can be
regenerated. It guarantees macOS↔Windows parity: the ONNX carries the exact weights
macOS already ships.

How it works: a `.mlmodelc` contains a human-readable `model.mil` (the graph, with
each learned tensor a `const()` pointing at an offset in `weights/weight.bin`) plus
the fp16 `weight.bin`. We parse the conv/prelu ops in order, resolve their weight/
bias/alpha consts to blob offsets, read them with coremltools' own blob reader, and
lay them into a SRVGGNetCompact state_dict.

Requirements:
    pip install torch coremltools numpy pillow

Usage:
    python scripts/recover_srvggnet_from_mlmodelc.py \
        --mlmodelc Bubilator88/Resources/SRVGGNet_x2.mlmodelc \
        --output models/SRVGGNet_x2.pth
"""

import argparse
import os
import re
import numpy as np
import torch

# Reuse the exact architecture + inference helpers from the ONNX converter.
import importlib.util
_spec = importlib.util.spec_from_file_location(
    "convsrv", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "convert_srvggnet_onnx.py"))
_c = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_c)
SRVGGNetCompact = _c.SRVGGNetCompact
infer_arch = _c.infer_arch


# Conv weights/biases are stored fp16, PReLU alphas fp32 — capture the dtype.
CONST_RE = re.compile(
    r'const\(\)\[name = string\("([^"]+)"\), '
    r'val = tensor<(fp16|fp32), \[([0-9, ]+)\]>\('
    r'BLOBFILE\(path = string\("[^"]*"\), offset = uint64\((\d+)\)\)\)\]')
CONV_RE = re.compile(r'= conv\(bias = ([^,]+),.*?weight = ([^,]+), x =')
PRELU_RE = re.compile(r'= prelu\(alpha = ([^,]+), x =')


def parse_mil(mil_path):
    """Return (consts, conv_ops, prelu_ops).
    consts: name -> (shape tuple, blob offset)
    conv_ops: [(weight_name, bias_name), ...] in graph order
    prelu_ops: [alpha_name, ...] in graph order"""
    text = open(mil_path).read()
    consts = {}
    for name, dtype, shape_s, off in CONST_RE.findall(text):
        shape = tuple(int(x) for x in shape_s.split(","))
        consts[name] = (dtype, shape, int(off))
    conv_ops = [(w, b) for (b, w) in CONV_RE.findall(text)]  # regex captures bias then weight
    prelu_ops = PRELU_RE.findall(text)
    return consts, conv_ops, prelu_ops


def read_blob(reader, consts, name):
    dtype, shape, off = consts[name.strip()]
    if dtype == "fp16":
        raw = np.array(reader.read_fp16_data(off), dtype=np.uint16)  # raw fp16 bits
        arr = raw.view(np.float16).astype(np.float32)
    else:  # fp32
        arr = np.array(reader.read_float_data(off), dtype=np.float32)
    return torch.from_numpy(arr.reshape(shape))


def recover(mlmodelc, output_pth):
    mil = os.path.join(mlmodelc, "model.mil")
    wbin = os.path.join(mlmodelc, "weights", "weight.bin")
    consts, conv_ops, prelu_ops = parse_mil(mil)
    print(f"Parsed {len(conv_ops)} conv ops, {len(prelu_ops)} prelu ops, "
          f"{len(consts)} weight consts")

    from coremltools.libmilstoragepython import _BlobStorageReader as BlobReader
    reader = BlobReader(wbin)

    state = {}
    # Convs -> body.0, body.2, ... (weight+bias). Prelus -> body.1, body.3, ... (weight=alpha).
    for i, (w_name, b_name) in enumerate(conv_ops):
        state[f"body.{2 * i}.weight"] = read_blob(reader, consts, w_name)
        state[f"body.{2 * i}.bias"] = read_blob(reader, consts, b_name)
    for j, a_name in enumerate(prelu_ops):
        alpha = read_blob(reader, consts, a_name).reshape(-1)  # PReLU weight is 1-D
        state[f"body.{2 * j + 1}.weight"] = alpha

    # Skip-connection mode is a graph choice, not a learned weight — read it from
    # the MIL so the rebuilt model matches (Balanced=nearest, Fast=bilinear).
    mil_text = open(mil).read()
    skip_mode = "nearest" if "upsample_nearest_neighbor" in mil_text else "bilinear"
    print(f"Detected skip mode: {skip_mode}")

    num_feat, num_conv = infer_arch(state)
    print(f"Recovered architecture: num_feat={num_feat}, num_conv={num_conv}")
    model = SRVGGNetCompact(num_feat=num_feat, num_conv=num_conv, skip_mode=skip_mode)
    model.load_state_dict(state, strict=True)
    model.eval()
    print(f"Rebuilt SRVGGNetCompact, {sum(p.numel() for p in model.parameters()):,} params")

    # Verify against the compiled CoreML model on a random frame.
    verify(model, mlmodelc)

    os.makedirs(os.path.dirname(output_pth) or ".", exist_ok=True)
    torch.save(model.state_dict(), output_pth)
    print(f"Saved recovered checkpoint: {output_pth}")


def verify(model, mlmodelc):
    import coremltools as ct
    from PIL import Image
    rng = np.random.default_rng(0)
    img = rng.integers(0, 256, size=(400, 640, 3), dtype=np.uint8)
    x = torch.from_numpy(img.astype(np.float32).transpose(2, 0, 1)[None] / 255.0)
    with torch.no_grad():
        ours = model(x).numpy().astype(np.float32)
    cm = ct.models.CompiledMLModel(mlmodelc)
    ref = np.asarray(cm.predict({"input": Image.fromarray(img, "RGB")})["output"],
                     dtype=np.float32)
    d = np.abs(ours - ref)
    print(f"Verify vs compiled CoreML: max|diff|={d.max():.5f} mean|diff|={d.mean():.6f}")
    if d.max() > 0.05:
        raise SystemExit("FAIL: recovered weights do not match the compiled model "
                         "(check the conv/prelu → body index mapping)")
    print("  PASS — recovered weights reproduce the shipped model within fp16.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mlmodelc", required=True, help="Path to a compiled .mlmodelc")
    ap.add_argument("--output", required=True, help="Output recovered .pth")
    args = ap.parse_args()
    recover(args.mlmodelc, args.output)


if __name__ == "__main__":
    main()
