#!/usr/bin/env python3
"""
generate_targets.py — RealESRGAN で正解画像を一括生成

Usage:
    python scripts/generate_targets.py /path/to/input_dir /path/to/output_dir

Input:  640x400 PNG screenshots (native PC-8801 resolution)
Output: 1280x800 PNG upscaled images (RealESRGAN x2)

Requirements:
    pip install torch torchvision pillow
    RealESRGAN_x2plus.pth in current directory or specify via WEIGHTS_PATH env
"""

import os
import sys
import glob
import urllib.request
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image
import numpy as np


# === RRDBNet architecture (same as convert_realesrgan.py) ===

def make_layer(block, n_layers, **kwargs):
    return nn.Sequential(*[block(**kwargs) for _ in range(n_layers)])


class ResidualDenseBlock(nn.Module):
    def __init__(self, num_feat=64, num_grow_ch=32):
        super().__init__()
        self.conv1 = nn.Conv2d(num_feat, num_grow_ch, 3, 1, 1)
        self.conv2 = nn.Conv2d(num_feat + num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv3 = nn.Conv2d(num_feat + 2 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv4 = nn.Conv2d(num_feat + 3 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv5 = nn.Conv2d(num_feat + 4 * num_grow_ch, num_feat, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, num_feat, num_grow_ch=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)

    def forward(self, x):
        out = self.rdb1(x)
        out = self.rdb2(out)
        out = self.rdb3(out)
        return out * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, scale=2, num_feat=64,
                 num_block=23, num_grow_ch=32):
        super().__init__()
        self.scale = scale
        if scale == 2:
            num_in_ch = num_in_ch * 4
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = make_layer(RRDB, num_block, num_feat=num_feat,
                               num_grow_ch=num_grow_ch)
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        if self.scale == 2:
            feat = F.pixel_unshuffle(x, 2)
        else:
            feat = x
        feat = self.conv_first(feat)
        body_feat = self.conv_body(self.body(feat))
        feat = feat + body_feat
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2,
                                                       mode='nearest')))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2,
                                                       mode='nearest')))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))


def download_weights(url, path):
    if os.path.exists(path):
        return
    print(f"Downloading weights to {path}...")
    urllib.request.urlretrieve(url, path)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input_dir> <output_dir>")
        sys.exit(1)

    input_dir = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    output_dir.mkdir(parents=True, exist_ok=True)

    # Load model
    weights_path = os.environ.get("WEIGHTS_PATH", "RealESRGAN_x2plus.pth")
    weights_url = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"
    download_weights(weights_url, weights_path)

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"Device: {device}")

    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23,
                    num_grow_ch=32, scale=2)
    state_dict = torch.load(weights_path, map_location="cpu", weights_only=True)
    if "params_ema" in state_dict:
        state_dict = state_dict["params_ema"]
    elif "params" in state_dict:
        state_dict = state_dict["params"]
    model.load_state_dict(state_dict, strict=True)
    model.eval().to(device)
    print(f"Model loaded: {sum(p.numel() for p in model.parameters()):,} params")

    # Process images
    png_files = sorted(input_dir.glob("*.png"))
    total = len(png_files)
    print(f"Processing {total} images...")

    done = 0
    skipped = 0
    for png_path in png_files:
        out_path = output_dir / png_path.name
        if out_path.exists():
            skipped += 1
            continue

        img = Image.open(png_path).convert("RGB")
        img_np = np.array(img).astype(np.float32) / 255.0
        # HWC -> CHW -> NCHW
        tensor = torch.from_numpy(img_np).permute(2, 0, 1).unsqueeze(0).to(device)

        with torch.no_grad():
            output = model(tensor)

        output = output.squeeze(0).clamp(0, 1).cpu().permute(1, 2, 0).numpy()
        output_img = Image.fromarray((output * 255).astype(np.uint8))
        output_img.save(str(out_path))

        done += 1
        if done % 100 == 0 or done == total - skipped:
            print(f"  [{done}/{total - skipped}] {png_path.name}")

    print(f"\n=== Done ===")
    print(f"  Processed: {done}")
    print(f"  Skipped: {skipped}")
    print(f"  Output: {output_dir}")


if __name__ == "__main__":
    main()
