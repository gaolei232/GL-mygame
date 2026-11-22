#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tex_tune.py —— 贴图后处理：按目标明度校正 + 压饱和 + 擦水印

为什么需要它：
  AI 出的贴图平均明度普遍偏亮（实测 plaza 41% vs 目标 30%，天空亮一倍）。
  靠"再生成一次"碰运气成本高，用 gamma 校正一次到位、可复现。

用法：
  python tex_tune.py <img> --target-l 30 --out out.png
  python tex_tune.py <img> --target-l 30 --sat 0.9 --patch-wm
  python tex_tune.py <img> --gamma 1.9 --patch-wm --out sky.png

参数：
  --target-l  目标平均明度（0-100），给了就自动解 gamma
  --gamma     直接指定 gamma，优先于 --target-l
  --sat       饱和度倍率（1.0 不变，0.9 = 压一档）
  --patch-wm  擦右下角水印（用同图左侧 340px 区域覆盖，带羽化）
  --report    打印校正前后的平均明度 / 饱和度

依赖：pillow
"""

from __future__ import annotations

import argparse
import math
import statistics
import sys
from pathlib import Path

try:
    from PIL import Image, ImageChops
except ImportError:
    sys.stderr.write("需要 pillow：pip install pillow\n")
    raise SystemExit(1)


def mean_l(im: Image.Image) -> float:
    small = im.convert("RGB").resize((96, 96))
    px = small.load()
    vals = [0.299 * px[x, y][0] + 0.587 * px[x, y][1] + 0.114 * px[x, y][2]
            for y in range(96) for x in range(96)]
    return statistics.mean(vals) / 255 * 100


def mean_s(im: Image.Image) -> float:
    small = im.convert("RGB").resize((96, 96))
    px = small.load()
    vals = []
    for y in range(96):
        for x in range(96):
            r, g, b = px[x, y]
            mx, mn = max(r, g, b), min(r, g, b)
            vals.append(0.0 if mx == 0 else (mx - mn) / mx * 100)
    return statistics.mean(vals)


def apply_gamma(im: Image.Image, gamma: float) -> Image.Image:
    lut = [min(255, max(0, int(round(255 * ((i / 255) ** gamma))))) for i in range(256)]
    return im.point(lut * 3)


def apply_sat(im: Image.Image, k: float) -> Image.Image:
    if abs(k - 1.0) < 1e-3:
        return im
    # 以感知灰度为中心做饱和度缩放
    gray = im.convert("L")
    gray_rgb = Image.merge("RGB", (gray, gray, gray))
    return Image.blend(gray_rgb, im, k)


def patch_watermark(im: Image.Image, block_w: int = 400, block_h: int = 150) -> Image.Image:
    """把右下角水印区用同一行的左侧内容覆盖。

    只对「左、上」两条边做 24px 羽化——右、下是画布边缘，接缝不可见，
    若也羽化会把贴边的水印原样留在羽化区里（第一版就是这么翻的）。
    """
    w, h = im.size
    x0, y0 = w - block_w, h - block_h
    src_x = max(0, x0 - block_w)
    patch = im.crop((src_x, y0, src_x + block_w, y0 + block_h))

    mask = Image.new("L", (block_w, block_h), 255)
    px = mask.load()
    feather = 24
    for y in range(block_h):
        for x in range(block_w):
            d = min(x, y)  # 只羽化左边和上边
            if d < feather:
                px[x, y] = int(255 * d / feather)
    im = im.copy()
    im.paste(patch, (x0, y0), mask)
    return im


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("img")
    ap.add_argument("--target-l", type=float, help="目标平均明度 0-100")
    ap.add_argument("--gamma", type=float, help="直接指定 gamma（>1 变暗）")
    ap.add_argument("--sat", type=float, default=1.0, help="饱和度倍率，默认 1.0")
    ap.add_argument("--patch-wm", action="store_true", help="擦右下角水印")
    ap.add_argument("--out")
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()

    src = Path(args.img)
    if not src.exists():
        sys.stderr.write(f"文件不存在：{src}\n")
        return 1

    im = Image.open(src).convert("RGB")
    l0, s0 = mean_l(im), mean_s(im)

    gamma = args.gamma
    if gamma is None and args.target_l:
        cur = l0 / 100
        tgt = args.target_l / 100
        if cur <= 0.001:
            sys.stderr.write("原图几乎全黑，无法推算 gamma\n")
            return 1
        gamma = math.log(tgt) / math.log(cur)
        gamma = round(gamma, 3)
    if gamma is None:
        gamma = 1.0

    im = apply_gamma(im, gamma)
    im = apply_sat(im, args.sat)
    if args.patch_wm:
        im = patch_watermark(im)

    dst = Path(args.out) if args.out else src.with_name(src.stem + "_tuned.png")
    im.save(dst)

    if args.report:
        l1, s1 = mean_l(im), mean_s(im)
        print(f"gamma        {gamma}")
        print(f"平均明度     {l0:.1f}% -> {l1:.1f}%  (目标 {args.target_l or '—'})")
        print(f"平均饱和度   {s0:.1f}% -> {s1:.1f}%")
        print(f"水印擦除     {'是' if args.patch_wm else '否'}")
    print(f"✅ 已输出：{dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
