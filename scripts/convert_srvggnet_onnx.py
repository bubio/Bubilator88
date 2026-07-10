#!/usr/bin/env python3
"""
Convert the PC-8801 self-trained SRVGGNet x2 models to ONNX for the Bubilator88
Windows / Linux shells.

These are the *Fast* (`SRVGGNet_x2_lite`) and *Balanced* (`SRVGGNet_x2`) filters.
Unlike Real-ESRGAN (Quality), there are **no public weights** — they were knowledge
-distilled locally (see scripts/train_srvggnet.py). The source-of-truth PyTorch
checkpoints are committed under models/ (Git LFS), so this conversion is fully
reproducible without the external training rig.

The macOS app runs the same weights through CoreML (baked into train_srvggnet.py's
convert_to_coreml); Windows/Linux run them through ONNX Runtime. This exports the
raw SRVGGNetCompact graph — input and output are float[0,1] RGB CHW tensors
(shapes [1,3,400,640] / [1,3,800,1280]). Normalization (/255) and de-normalization
(*255) are done by the host (AiUpscaler.cs), exactly like convert_realesrgan_onnx.py
and the macOS MultiArray float path in AIUpscaler.swift.

Requirements:
    pip install torch

The skip-connection upsample mode is NOT stored in the checkpoint and differs per
model (Fast=bilinear, Balanced=nearest — verified against the shipped CoreML models),
so it is pinned in the MODELS registry below / passed via --skip-mode.

Usage:
    # Convert both committed checkpoints with their pinned skip modes:
    python scripts/convert_srvggnet_onnx.py

    # Convert a single checkpoint explicitly:
    python scripts/convert_srvggnet_onnx.py \
        --checkpoint models/SRVGGNet_x2.pth \
        --output models/onnx/SRVGGNet_x2.onnx --skip-mode nearest

Output (committed to the repo via Git LFS — nobody else can regenerate these):
    models/onnx/SRVGGNet_x2.onnx       (Balanced, from models/SRVGGNet_x2.pth)
    models/onnx/SRVGGNet_x2_lite.onnx  (Fast,     from models/SRVGGNet_x2_lite.pth)
"""

import argparse
import os
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F


# === SRVGGNetCompact (identical architecture to scripts/train_srvggnet.py) ===

class SRVGGNetCompact(nn.Module):
    """VGG-style compact super-resolution network (Real-ESRGAN compact variant).
    Kept byte-for-byte compatible with train_srvggnet.py so a checkpoint saved
    there loads here without surprises."""

    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64,
                 num_conv=16, upscale=2, act_type='prelu', skip_mode='bilinear'):
        super().__init__()
        self.upscale = upscale
        # Skip-connection upsample mode. train_srvggnet.py uses 'bilinear', but the
        # shipped Balanced model (SRVGGNet_x2) was trained with 'nearest' — it is NOT
        # stored in the checkpoint, so it must be supplied per model (see the MODELS
        # registry / recover_srvggnet_from_mlmodelc.py's MIL detection).
        self.skip_mode = skip_mode

        self.body = nn.ModuleList()
        # First conv
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(self._make_act(act_type, num_feat))
        # Body convs
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(self._make_act(act_type, num_feat))
        # Last conv (output channels for pixel shuffle)
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def _make_act(self, act_type, num_feat):
        if act_type == 'relu':
            return nn.ReLU(inplace=True)
        elif act_type == 'prelu':
            return nn.PReLU(num_parameters=num_feat)
        elif act_type == 'leakyrelu':
            return nn.LeakyReLU(negative_slope=0.1, inplace=True)
        else:
            raise ValueError(f'Unknown act_type: {act_type}')

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        # Skip connection: upsampled input + network residual. Exports cleanly to an
        # ONNX Resize op under opset 17 for both modes.
        if self.skip_mode == 'nearest':
            base = F.interpolate(x, scale_factor=self.upscale, mode='nearest')
        else:
            base = F.interpolate(x, scale_factor=self.upscale, mode='bilinear',
                                 align_corners=False)
        return base + out


# === Architecture inference ===

def infer_arch(state_dict):
    """Recover (num_feat, num_conv) from a checkpoint's weight shapes.

    The Fast (lite) model was trained with smaller hyper-parameters than the
    Balanced default (64/16), and the value isn't stored anywhere but the tensor
    shapes — so we read it back instead of hard-coding, which is the one real
    gotcha of this conversion.

    Body layout (ModuleList indices):
        body.0            first conv (num_in_ch -> num_feat)
        body.1            act
        body.2 / body.3   conv/act   ]
        ...                          } num_conv pairs
        body.{2*n} / ...  conv/act   ]
        body.{2*n+2}      last conv (num_feat -> num_out_ch*upscale^2)
    so the highest body index is 2*num_conv + 2.
    """
    if 'body.0.weight' not in state_dict:
        raise ValueError("Not an SRVGGNetCompact checkpoint (no 'body.0.weight')")
    num_feat = state_dict['body.0.weight'].shape[0]

    conv_indices = [
        int(k.split('.')[1])
        for k in state_dict
        if k.startswith('body.') and k.endswith('.weight')
        and state_dict[k].dim() == 4  # Conv2d weights are 4-D; PReLU weights are 1-D
    ]
    last_idx = max(conv_indices)
    num_conv = (last_idx - 2) // 2
    return num_feat, num_conv


def equalize_activations(model, seed=0, num_probes=3):
    """Rescale conv weights so intermediate activations are ~O(1) WITHOUT changing
    the output. PReLU is positive-homogeneous (PReLU(a*x) = a*PReLU(x) for a>0), so a
    per-layer scale on each PReLU output can be pushed into the surrounding convs and
    cancels exactly. This keeps the model mathematically identical to the shipped
    CoreML model while removing the catastrophic-cancellation precision loss that
    large-magnitude weights suffer under DirectML's fp16 execution.

    The recovered Balanced model is the motivating case: max|weight| ~42 and peak
    activation ~413, which renders correctly on CPU/CoreML but collapses to garbage on
    DirectML (Windows). After equalization max|weight| drops to ~2 and peak activation
    to ~1, and the output is bit-for-bit equivalent (fp32 rounding only). It is a
    harmless no-op for already well-scaled models (e.g. Fast, peak ~2)."""
    import numpy as _np
    body = model.body
    conv_idx = [i for i in range(len(body))
                if hasattr(body[i], "weight") and body[i].weight.dim() == 4]
    prelu_idx = [i for i in range(len(body)) if i not in conv_idx]

    # Peak |PReLU output| per prelu, over a few random [0,1] probes (safety margin).
    rng = _np.random.default_rng(seed)
    peaks = [0.0] * len(prelu_idx)
    with torch.no_grad():
        for _ in range(num_probes):
            x = torch.from_numpy(rng.random((1, 3, 400, 640), dtype=_np.float32))
            o, j = x, 0
            for i, layer in enumerate(body):
                o = layer(o)
                if i in prelu_idx:
                    peaks[j] = max(peaks[j], float(o.abs().max()))
                    j += 1

    c = [1.0 / max(p, 1e-6) for p in peaks]  # target each PReLU output ~1
    with torch.no_grad():
        prev = 1.0
        # conv_idx[k] feeds prelu k (k = 0..len(prelu)-1); scale W by c_k/c_{k-1},
        # bias by c_k. The final conv (conv_idx[-1], no following prelu) undoes the
        # last scale so the body output is unchanged.
        for k, ci in enumerate(conv_idx[:-1]):
            body[ci].weight.mul_(c[k] / prev)
            body[ci].bias.mul_(c[k])
            prev = c[k]
        body[conv_idx[-1]].weight.mul_(1.0 / prev)
    return model


def unwrap_state(raw):
    """Accept a bare state_dict (train_srvggnet.py saves this) or a wrapped
    checkpoint ('params_ema' / 'params'), matching the other convert scripts."""
    if isinstance(raw, dict) and 'body.0.weight' not in raw:
        if 'params_ema' in raw:
            return raw['params_ema']
        if 'params' in raw:
            return raw['params']
    return raw


# === Conversion ===

def convert_one(checkpoint_path, output_path, skip_mode='bilinear'):
    print(f"Converting {checkpoint_path} -> {output_path} (skip={skip_mode})")

    print("  Step 1/3: Load checkpoint")
    raw = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
    state_dict = unwrap_state(raw)
    num_feat, num_conv = infer_arch(state_dict)
    print(f"    Inferred architecture: num_feat={num_feat}, num_conv={num_conv}")

    model = SRVGGNetCompact(num_in_ch=3, num_out_ch=3, num_feat=num_feat,
                            num_conv=num_conv, upscale=2, act_type='prelu',
                            skip_mode=skip_mode)
    model.load_state_dict(state_dict, strict=True)
    model.eval()
    print(f"    Loaded {sum(p.numel() for p in model.parameters()):,} parameters")

    # Well-condition the weights for DirectML fp16 (exact, output-preserving).
    wmax = lambda: max(float(p.detach().abs().max()) for p in model.parameters())
    before = wmax()
    equalize_activations(model)
    print(f"    Activation equalization: max|weight| {before:.2f} -> {wmax():.2f}")

    print("  Step 2/3: Verify trace (input: 1x3x400x640)")
    input_shape = (1, 3, 400, 640)
    example_input = torch.randn(input_shape)
    with torch.no_grad():
        out = model(example_input)
        print(f"    Output shape: {tuple(out.shape)} (expected: (1, 3, 800, 1280))")
    assert tuple(out.shape) == (1, 3, 800, 1280), "unexpected output shape"

    print("  Step 3/3: Export to ONNX")
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    # Fixed input shape + legacy exporter (dynamo=False) so the weights are EMBEDDED
    # in a single self-contained .onnx — same rationale as convert_realesrgan_onnx.py.
    torch.onnx.export(
        model,
        example_input,
        output_path,
        input_names=["input"],
        output_names=["output"],
        opset_version=17,
        do_constant_folding=True,
        dynamo=False,
    )
    size_mb = os.path.getsize(output_path) / 1024 / 1024
    print(f"    Saved {output_path} ({size_mb:.2f} MB)")


# Source-of-truth registry: (checkpoint, output ONNX, skip_mode). The skip mode is
# NOT stored in the checkpoint, so it is pinned here per model (Fast was trained with
# a bilinear skip, Balanced with a nearest skip — verified against the shipped
# CoreML models). Both .pth live in models/ (Git LFS):
#   SRVGGNet_x2_lite.pth = the Fast training checkpoint (SRVGGNet_x2_pc88_lite_final)
#   SRVGGNet_x2.pth      = weights recovered from the shipped Balanced .mlmodelc
#                          (see recover_srvggnet_from_mlmodelc.py)
MODELS = [
    ("models/SRVGGNet_x2_lite.pth", "models/onnx/SRVGGNet_x2_lite.onnx", "bilinear"),
    ("models/SRVGGNet_x2.pth",      "models/onnx/SRVGGNet_x2.onnx",      "nearest"),
]


def main():
    parser = argparse.ArgumentParser(
        description="Convert self-trained SRVGGNet x2 checkpoints to ONNX")
    parser.add_argument("--checkpoint", help="Single .pth to convert "
                        "(default: both committed SRVGGNet checkpoints)")
    parser.add_argument("--output", help="Output .onnx path (required with --checkpoint)")
    parser.add_argument("--skip-mode", choices=["bilinear", "nearest"],
                        default="bilinear",
                        help="Skip-connection upsample mode (default: bilinear)")
    args = parser.parse_args()

    # Resolve paths relative to the repo root (parent of scripts/), so the script
    # works from any CWD.
    repo_root = Path(__file__).resolve().parent.parent

    if args.checkpoint:
        if not args.output:
            parser.error("--output is required when --checkpoint is given")
        convert_one(args.checkpoint, args.output, args.skip_mode)
        return

    for ckpt, out, skip_mode in MODELS:
        ckpt_path = repo_root / ckpt
        out_path = repo_root / out
        if not ckpt_path.exists():
            print(f"SKIP: {ckpt_path} not found "
                  f"(run `git lfs pull`, or pass --checkpoint explicitly)")
            continue
        convert_one(str(ckpt_path), str(out_path), skip_mode)

    print("\nDone. These ONNX files are the ONLY distributable form of the "
          "self-trained models — commit them via Git LFS.")


if __name__ == "__main__":
    main()
