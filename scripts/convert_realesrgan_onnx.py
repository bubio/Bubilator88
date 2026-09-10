#!/usr/bin/env python3
"""
Convert Real-ESRGAN x2 model to ONNX format for the Bubilator88 Windows shell.

The macOS app runs the same weights through CoreML (see convert_realesrgan.py);
Windows runs them through ONNX Runtime + DirectML instead. This exports the raw
RRDBNet graph — input and output are float[0,1] RGB CHW tensors. Normalization
(/255) and de-normalization (*255) are done by the host (AiUpscaler.cs), exactly
like the macOS MultiArray float path in AIUpscaler.swift.

Requirements:
    pip install torch

Usage:
    python scripts/convert_realesrgan_onnx.py

Output:
    models/onnx/RealESRGAN_x2.onnx

This is the shared, cross-platform model location: the Windows csproj (and a future
Linux shell) copy models/onnx/*.onnx next to the executable. Unlike the self-trained
SRVGGNet models (which MUST be committed via Git LFS — no public weights exist), this
Quality model is regenerable from public weights, so committing it is optional.
"""

import sys
import os
import urllib.request

import torch
import torch.nn as nn
import torch.nn.functional as F


# === RRDBNet architecture (self-contained; identical to convert_realesrgan.py) ===

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
    weights_url = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"
    weights_path = "RealESRGAN_x2plus.pth"

    print("Step 1/4: Download weights")
    download_weights(weights_url, weights_path)

    print("Step 2/4: Load model")
    model = RRDBNet(num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32, scale=2)
    state_dict = torch.load(weights_path, map_location="cpu", weights_only=True)
    if "params_ema" in state_dict:
        state_dict = state_dict["params_ema"]
    elif "params" in state_dict:
        state_dict = state_dict["params"]
    model.load_state_dict(state_dict, strict=True)
    model.eval()
    print(f"  Loaded {sum(p.numel() for p in model.parameters()):,} parameters")

    print("Step 3/4: Verify trace (input: 1x3x400x640)")
    input_shape = (1, 3, 400, 640)
    example_input = torch.randn(input_shape)
    with torch.no_grad():
        out = model(example_input)
        print(f"  Output shape: {tuple(out.shape)} (expected: (1, 3, 800, 1280))")

    print("Step 4/4: Export to ONNX")
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    output_path = os.path.join(repo_root, "models", "onnx", "RealESRGAN_x2.onnx")
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    # Fixed input shape (we always feed the full 640x400 frame, even in 200-line
    # mode — matching macOS). No dynamic axes keeps the DirectML graph simplest.
    #
    # dynamo=False uses the legacy TorchScript exporter, which EMBEDS the weights
    # into a single self-contained .onnx (~65 MB). The new dynamo exporter
    # externalizes them into a sidecar RealESRGAN_x2.onnx.data, which is easy to
    # forget to ship — a single file is simpler to bundle.
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
    print(f"\nDone! Saved to {output_path} ({size_mb:.1f} MB)")
    print()
    print("The Windows build copies models/onnx/*.onnx next to the exe automatically.")
    print("Committing this Quality model is optional (regenerable from public weights);")
    print("the self-trained SRVGGNet models must be committed via Git LFS.")


if __name__ == "__main__":
    main()
