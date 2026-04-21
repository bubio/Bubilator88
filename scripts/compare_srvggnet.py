#!/usr/bin/env python3
"""
compare_srvggnet.py — 学習済みSRVGGNet モデルと Real-ESRGAN 正解画像の視覚比較

Usage:
    source /Volumes/CrucialX6/temp/venv/bin/activate
    python scripts/compare_srvggnet.py \\
        --input /Volumes/CrucialX6/temp/screenshots_filtered \\
        --target /Volumes/CrucialX6/temp/targets \\
        --weights /Volumes/CrucialX6/temp/training/SRVGGNet_x2_pc88_lite_best.pth \\
        --num_feat 32 --num_conv 12 \\
        --output /tmp/lite_comparison \\
        --samples 6

各サンプルにつき、以下を1枚にレイアウトしたPNGを出力:
  [Original 640x400 (nearest x2)] [Real-ESRGAN target] [SRVGGNet output]
"""

import argparse
import random
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageDraw, ImageFont


# === SRVGGNetCompact (train_srvggnet.py と同一) ===

class SRVGGNetCompact(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64,
                 num_conv=16, upscale=2, act_type='prelu'):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        base = F.interpolate(x, scale_factor=self.upscale, mode='bilinear',
                             align_corners=False)
        return base + out


def load_model(weights_path, num_feat, num_conv, device):
    model = SRVGGNetCompact(num_feat=num_feat, num_conv=num_conv).to(device)
    state = torch.load(weights_path, map_location=device, weights_only=True)
    model.load_state_dict(state)
    model.eval()
    return model


def infer(model, img_path, device):
    img = Image.open(img_path).convert("RGB")
    arr = np.array(img, dtype=np.float32) / 255.0
    tensor = torch.from_numpy(arr).permute(2, 0, 1).unsqueeze(0).to(device)
    with torch.no_grad():
        out = model(tensor)
    out = out.clamp(0, 1).squeeze(0).permute(1, 2, 0).cpu().numpy()
    # Round-half-up before truncation so 1.0 maps to 255 (not 254).
    out_uint8 = np.clip(np.round(out * 255.0), 0, 255).astype(np.uint8)
    return Image.fromarray(out_uint8)


def make_label_strip(text, width, height=24):
    """ラベル帯を生成"""
    img = Image.new("RGB", (width, height), (32, 32, 32))
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 16)
    except Exception:
        font = ImageFont.load_default()
    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    draw.text(((width - tw) // 2, (height - th) // 2 - 2), text,
              fill=(220, 220, 220), font=font)
    return img


def make_comparison(input_path, target_path, output_pil, save_path):
    """3カラムレイアウトで保存。各カラム1280x800"""
    cell_w, cell_h = 1280, 800
    label_h = 28
    margin = 8

    # Original: nearest neighbor x2 から拡大
    orig = Image.open(input_path).convert("RGB")
    orig_up = orig.resize((cell_w, cell_h), Image.NEAREST)

    target = Image.open(target_path).convert("RGB").resize((cell_w, cell_h))
    output = output_pil.resize((cell_w, cell_h))

    total_w = cell_w * 3 + margin * 4
    total_h = cell_h + label_h * 2 + margin * 3

    canvas = Image.new("RGB", (total_w, total_h), (16, 16, 16))

    # ファイル名表示
    title = make_label_strip(input_path.name, total_w, label_h)
    canvas.paste(title, (0, margin))

    labels = ["Original (640x400 nearest x2)",
              "Real-ESRGAN (target)",
              "SRVGGNet lite (32ch x 12 layers)"]
    images = [orig_up, target, output]
    y = margin * 2 + label_h
    for i, (img, label) in enumerate(zip(images, labels)):
        x = margin + i * (cell_w + margin)
        lbl = make_label_strip(label, cell_w, label_h)
        canvas.paste(lbl, (x, y))
        canvas.paste(img, (x, y + label_h))

    canvas.save(save_path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--weights", required=True)
    parser.add_argument("--num_feat", type=int, default=32)
    parser.add_argument("--num_conv", type=int, default=12)
    parser.add_argument("--output", required=True)
    parser.add_argument("--samples", type=int, default=6)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--names", nargs="*", default=None,
                        help="特定のファイル名を指定 (拡張子なし可)")
    args = parser.parse_args()

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"Device: {device}")

    model = load_model(args.weights, args.num_feat, args.num_conv, device)
    num_params = sum(p.numel() for p in model.parameters())
    print(f"Model: feat={args.num_feat} conv={args.num_conv} ({num_params:,} params)")

    input_dir = Path(args.input)
    target_dir = Path(args.target)
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    pairs = []
    for inp in sorted(input_dir.glob("*.png")):
        tgt = target_dir / inp.name
        if tgt.exists():
            pairs.append((inp, tgt))

    if args.names:
        wanted = {n if n.endswith(".png") else f"{n}.png" for n in args.names}
        pairs = [(i, t) for i, t in pairs if i.name in wanted]
        print(f"Filtered to {len(pairs)} requested names")
    else:
        random.seed(args.seed)
        pairs = random.sample(pairs, min(args.samples, len(pairs)))

    print(f"Processing {len(pairs)} samples...")
    for inp, tgt in pairs:
        out = infer(model, inp, device)
        save_path = output_dir / f"compare_{inp.stem}.png"
        make_comparison(inp, tgt, out, save_path)
        print(f"  saved: {save_path}")

    print(f"\nDone. Output: {output_dir}")


if __name__ == "__main__":
    main()
