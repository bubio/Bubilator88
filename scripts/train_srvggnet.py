#!/usr/bin/env python3
"""
train_srvggnet.py — PC-8801特化SRVGGNet x2の知識蒸留学習

Usage:
    source /Volumes/CrucialX6/temp/venv/bin/activate
    python scripts/train_srvggnet.py \\
        --input /Volumes/CrucialX6/temp/screenshots_filtered \\
        --target /Volumes/CrucialX6/temp/targets \\
        --output /Volumes/CrucialX6/temp/training

Input:  640x400 PNG (native) + 1280x800 PNG (RealESRGAN target)
Output: SRVGGNet_x2_pc88.pth + SRVGGNet_x2_pc88.mlpackage
"""

import argparse
import os
import sys
import random
from pathlib import Path

# Disable output buffering (works even with file redirect)
sys.stdout.reconfigure(line_buffering=True)
os.environ["PYTHONUNBUFFERED"] = "1"

_orig_print = print
def print(*args, **kwargs):
    kwargs.setdefault("flush", True)
    _orig_print(*args, **kwargs)

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader
from PIL import Image
import numpy as np


# === SRVGGNetCompact (Real-ESRGAN lightweight architecture) ===

class SRVGGNetCompact(nn.Module):
    """VGG-style super-resolution network (compact version).
    Same architecture as realesrgan-x2plus's compact model.
    """
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64,
                 num_conv=16, upscale=2, act_type='prelu'):
        super().__init__()
        self.upscale = upscale

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
        # Skip connection: bilinear upsample input + network residual
        base = F.interpolate(x, scale_factor=self.upscale, mode='bilinear',
                             align_corners=False)
        return base + out


# === Dataset ===

class PC88PatchDataset(Dataset):
    """Random crop patches from input/target pairs. All images preloaded."""

    def __init__(self, input_dir, target_dir, patch_size=128, scale=2):
        self.patch_size = patch_size
        self.scale = scale

        input_dir = Path(input_dir)
        target_dir = Path(target_dir)

        # Find matching pairs and preload all images
        self.inputs = []
        self.targets = []
        pairs = []
        for inp in sorted(input_dir.glob("*.png")):
            tgt = target_dir / inp.name
            if tgt.exists():
                pairs.append((inp, tgt))

        print(f"Loading {len(pairs)} image pairs into memory...")
        for i, (inp_path, tgt_path) in enumerate(pairs):
            inp_img = np.array(Image.open(inp_path).convert("RGB"), dtype=np.float32) / 255.0
            tgt_img = np.array(Image.open(tgt_path).convert("RGB"), dtype=np.float32) / 255.0
            self.inputs.append(inp_img)
            self.targets.append(tgt_img)
            if (i + 1) % 500 == 0:
                print(f"  {i + 1}/{len(pairs)} loaded")

        print(f"Dataset ready: {len(self.inputs)} pairs, patch_size={patch_size}")

    def __len__(self):
        return len(self.inputs)

    def __getitem__(self, idx):
        pair_idx = idx % len(self.inputs)
        inp_img = self.inputs[pair_idx]
        tgt_img = self.targets[pair_idx]

        h, w = inp_img.shape[:2]
        ps = self.patch_size

        # Random crop
        top = random.randint(0, h - ps)
        left = random.randint(0, w - ps)
        inp_patch = inp_img[top:top+ps, left:left+ps]
        t_top, t_left, t_ps = top * self.scale, left * self.scale, ps * self.scale
        tgt_patch = tgt_img[t_top:t_top+t_ps, t_left:t_left+t_ps]

        # Random horizontal flip
        if random.random() > 0.5:
            inp_patch = inp_patch[:, ::-1].copy()
            tgt_patch = tgt_patch[:, ::-1].copy()

        inp_tensor = torch.from_numpy(inp_patch).permute(2, 0, 1)
        tgt_tensor = torch.from_numpy(tgt_patch).permute(2, 0, 1)

        return inp_tensor, tgt_tensor


# === Training ===

def train(args):
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Auto-detect best device
    device_env = os.environ.get("DEVICE", "auto")
    if device_env == "auto":
        if torch.backends.mps.is_available():
            device = "mps"
        elif torch.cuda.is_available():
            device = "cuda"
        else:
            device = "cpu"
    else:
        device = device_env
    print(f"Device: {device}")

    # Model
    model = SRVGGNetCompact(
        num_in_ch=3, num_out_ch=3,
        num_feat=args.num_feat, num_conv=args.num_conv,
        upscale=2, act_type='prelu'
    ).to(device)

    num_params = sum(p.numel() for p in model.parameters())
    print(f"Model: SRVGGNetCompact feat={args.num_feat} conv={args.num_conv} "
          f"({num_params:,} params)")

    # Optionally load pretrained weights
    if args.pretrained and os.path.exists(args.pretrained):
        state = torch.load(args.pretrained, map_location="cpu", weights_only=True)
        if "params_ema" in state:
            state = state["params_ema"]
        elif "params" in state:
            state = state["params"]
        model.load_state_dict(state, strict=False)
        print(f"Loaded pretrained: {args.pretrained}")

    # Dataset
    dataset = PC88PatchDataset(args.input, args.target,
                                patch_size=args.patch_size)
    loader = DataLoader(dataset, batch_size=args.batch_size,
                        shuffle=True, num_workers=0)

    # Loss: L1 + perceptual-like (weighted high-frequency)
    l1_loss = nn.L1Loss()

    # Optimizer
    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=args.epochs, eta_min=args.lr * 0.01)

    # Training loop
    import time
    best_loss = float('inf')
    for epoch in range(1, args.epochs + 1):
        model.train()
        epoch_loss = 0
        batch_count = 0
        t0 = time.time()

        for inp, tgt in loader:
            inp = inp.to(device)
            tgt = tgt.to(device)

            output = model(inp)
            loss = l1_loss(output, tgt)

            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

            epoch_loss += loss.item()
            batch_count += 1

        if device == "mps":
            torch.mps.synchronize()
        elapsed = time.time() - t0
        scheduler.step()
        avg_loss = epoch_loss / max(batch_count, 1)

        lr = optimizer.param_groups[0]['lr']
        print(f"Epoch {epoch:4d}/{args.epochs}  loss={avg_loss:.6f}  lr={lr:.2e}  {elapsed:.1f}s  batches={batch_count}")

        # Save best
        if avg_loss < best_loss:
            best_loss = avg_loss
            torch.save(model.state_dict(),
                       str(output_dir / f"{args.model_name}_best.pth"))

        # Periodic save
        if epoch % 50 == 0:
            torch.save(model.state_dict(),
                       str(output_dir / f"{args.model_name}_e{epoch:04d}.pth"))

    # Final save
    torch.save(model.state_dict(),
               str(output_dir / f"{args.model_name}_final.pth"))
    print(f"\nTraining complete. Best loss: {best_loss:.6f}")
    print(f"Weights saved to: {output_dir}")

    # Convert to CoreML
    convert_to_coreml(model, output_dir, device, args.model_name)


def convert_to_coreml(model, output_dir, device, model_name="SRVGGNet_x2_pc88"):
    try:
        import coremltools as ct
    except ImportError:
        print("coremltools not available, skipping CoreML conversion")
        return

    print("\nConverting to CoreML...")
    model.eval().cpu()
    input_shape = (1, 3, 400, 640)
    example = torch.randn(input_shape)

    with torch.no_grad():
        traced = torch.jit.trace(model, example)
        out = traced(example)
        print(f"  Output shape: {out.shape}")

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="input",
                shape=input_shape,
                scale=1.0 / 255.0,
                bias=[0, 0, 0],
                color_layout="RGB",
            )
        ],
        outputs=[
            ct.TensorType(name="output")
        ],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS15,
    )

    mlpackage_path = str(output_dir / f"{model_name}.mlpackage")
    mlmodel.save(mlpackage_path)
    print(f"  CoreML model saved: {mlpackage_path}")
    print(f"\n  To compile and install:")
    print(f"    xcrun coremlcompiler compile {mlpackage_path} .")
    print(f"    cp -r {model_name}.mlmodelc ~/Library/Application\\ Support/Bubilator88/Models/")


def main():
    parser = argparse.ArgumentParser(description="Train SRVGGNet for PC-8801")
    parser.add_argument("--input", required=True, help="Input images dir (640x400)")
    parser.add_argument("--target", required=True, help="Target images dir (1280x800)")
    parser.add_argument("--output", required=True, help="Output dir for weights")
    parser.add_argument("--pretrained", default="", help="Pretrained weights path")
    parser.add_argument("--num_feat", type=int, default=64, help="Feature channels")
    parser.add_argument("--num_conv", type=int, default=16, help="Body conv layers")
    parser.add_argument("--model_name", default="SRVGGNet_x2_pc88",
                        help="Filename prefix used for .pth checkpoints, "
                             ".mlpackage, and .mlmodelc outputs")
    parser.add_argument("--patch_size", type=int, default=128, help="Training patch size")
    parser.add_argument("--batch_size", type=int, default=16, help="Batch size")
    parser.add_argument("--epochs", type=int, default=200, help="Training epochs")
    parser.add_argument("--lr", type=float, default=2e-4, help="Learning rate")
    args = parser.parse_args()

    train(args)


if __name__ == "__main__":
    main()
