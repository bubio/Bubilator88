#!/usr/bin/env python3
"""
Convert Real-ESRGAN x2 model to CoreML format for Bubilator88.

Requirements:
    pip install coremltools torch

Usage:
    python scripts/convert_realesrgan.py

Output:
    RealESRGAN_x2.mlpackage  (then compile and copy to Application Support)
"""

import sys
import os
import math
import urllib.request

import torch
import torch.nn as nn
import torch.nn.functional as F


# === RRDBNet architecture (from basicsr, self-contained to avoid import issues) ===

def make_layer(block, n_layers, **kwargs):
    layers = [block(**kwargs) for _ in range(n_layers)]
    return nn.Sequential(*layers)


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
    def __init__(self, num_in_ch=3, num_out_ch=3, scale=2, num_feat=64, num_block=23, num_grow_ch=32):
        super().__init__()
        self.scale = scale
        if scale == 2:
            num_in_ch = num_in_ch * 4  # pixel unshuffle for x2
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = make_layer(RRDB, num_block, num_feat=num_feat, num_grow_ch=num_grow_ch)
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        # upsample (2 stages of x2 = x4 total, but pixel_unshuffle halves for x2 scale)
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
        # upsample (x2 each stage, pixel_unshuffle compensates for x2 model)
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode='nearest')))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode='nearest')))
        out = self.conv_last(self.lrelu(self.conv_hr(feat)))
        return out


# === Main conversion ===

def download_weights(url, path):
    if os.path.exists(path):
        print(f"  Using cached {path}")
        return
    print(f"  Downloading {url}...")
    urllib.request.urlretrieve(url, path)
    print(f"  Saved to {path}")


def main():
    try:
        import coremltools as ct
    except ImportError:
        print("Missing coremltools. Install with: pip install coremltools")
        sys.exit(1)

    weights_url = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"
    weights_path = "RealESRGAN_x2plus.pth"

    print("Step 1/4: Download weights")
    download_weights(weights_url, weights_path)

    print("Step 2/4: Load model")
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=2)
    state_dict = torch.load(weights_path, map_location="cpu", weights_only=True)
    # Handle 'params_ema' key if present
    if "params_ema" in state_dict:
        state_dict = state_dict["params_ema"]
    elif "params" in state_dict:
        state_dict = state_dict["params"]
    model.load_state_dict(state_dict, strict=True)
    model.eval()
    print(f"  Loaded {sum(p.numel() for p in model.parameters()):,} parameters")

    print("Step 3/4: Trace model (input: 1x3x400x640)")
    input_shape = (1, 3, 400, 640)
    example_input = torch.randn(input_shape)
    with torch.no_grad():
        traced = torch.jit.trace(model, example_input)
        # Verify output shape
        out = traced(example_input)
        print(f"  Output shape: {out.shape} (expected: 1x3x800x1280)")

    print("Step 4/4: Convert to CoreML")
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
            ct.ImageType(
                name="output",
                color_layout="RGB",
            )
        ],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS15,
    )

    output_path = "RealESRGAN_x2.mlpackage"
    mlmodel.save(output_path)

    # Calculate size
    total_size = 0
    for dirpath, dirnames, filenames in os.walk(output_path):
        for f in filenames:
            total_size += os.path.getsize(os.path.join(dirpath, f))

    print(f"\nDone! Saved to {output_path} ({total_size / 1024 / 1024:.1f} MB)")
    print()
    print("Next steps:")
    print(f"  xcrun coremlcompiler compile {output_path} .")
    print("  mkdir -p ~/Library/Application\\ Support/Bubilator88/Models/")
    print("  cp -r RealESRGAN_x2.mlmodelc ~/Library/Application\\ Support/Bubilator88/Models/")


if __name__ == "__main__":
    main()
