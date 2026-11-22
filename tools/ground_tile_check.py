#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ground_tile_check.py —— 地面贴图规格校验/预处理（供 tex_ground_*_tile_v2 使用）。

输入：用户生成的原图（任意尺寸）
输出：1024² RGB PNG + 2x2 平铺接缝图 + 报告

处理：
  1) 非方形输入居中裁最大方形，再 resize 到 1024²；
  2) 平均明度压到目标（plaza L30 / wilds L23 / scrub L23）；
  3) 压饱和度到 0.9 倍（低饱和土石）；
  4) 接缝只测不修：左右/上下列平均差，< 8 可用，> 8 必须靠引擎 4 向随机铺贴。
"""
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageEnhance
import numpy as np

TARGET_L = {"plaza": 30.0, "wilds": 23.0, "scrub": 23.0}


def _mean_luma(im: Image.Image) -> float:
    a = np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0
    return float(np.mean(a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722) * 100.0)


def _mean_sat(im: Image.Image) -> float:
    a = np.asarray(im.convert("RGB"), dtype=np.float32) / 255.0
    mx, mn = a.max(axis=2), a.min(axis=2)
    sat = np.divide(mx - mn, np.maximum(mx, 1e-6), out=np.zeros_like(mx), where=mx > 1e-6)
    return float(np.mean(sat) * 100.0)


def _fit_luma(im: Image.Image, target: float) -> tuple[Image.Image, float]:
    cur = _mean_luma(im)
    im = ImageEnhance.Brightness(im).enhance(target / max(cur, 1e-6))
    cur = _mean_luma(im)
    if abs(cur - target) > 0.75:
        gamma = float(np.clip(np.log(max(target, 1e-6) / 100.0) / np.log(max(cur, 1e-6) / 100.0), 0.75, 1.25))
        lut = [int(round(255 * ((i / 255.0) ** gamma))) for i in range(256)]
        im = im.point(lut * 3)
    return im, _mean_luma(im)


def _seam(im: Image.Image) -> dict[str, float]:
    a = np.asarray(im.convert("RGB"), dtype=np.float32)
    return {
        "lr": float(np.mean(np.abs(a[:, 0] - a[:, -1]))),
        "tb": float(np.mean(np.abs(a[0, :] - a[-1, :]))),
    }


def _preview_2x2(im: Image.Image, out: Path) -> None:
    w, h = im.size
    sheet = Image.new("RGB", (w * 2, h * 2))
    for x in (0, w):
        for y in (0, h):
            sheet.paste(im, (x, y))
    sheet.resize((768, 768), Image.Resampling.LANCZOS).save(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("img")
    ap.add_argument("--kind", required=True, choices=sorted(TARGET_L))
    ap.add_argument("--out", required=True)
    ap.add_argument("--preview", help="2x2 平铺接缝预览图")
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()

    src = Path(args.img)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    im = Image.open(src).convert("RGB")
    raw_size = im.size
    if im.width != im.height:
        side = min(im.size)
        left = (im.width - side) // 2
        top = (im.height - side) // 2
        im = im.crop((left, top, left + side, top + side))
    im = im.resize((1024, 1024), Image.Resampling.LANCZOS)

    l0, s0 = _mean_luma(im), _mean_sat(im)
    im, l1 = _fit_luma(im, TARGET_L[args.kind])
    im = ImageEnhance.Color(im).enhance(0.9)
    s1 = _mean_sat(im)
    seams = _seam(im)
    im.save(out)
    if args.preview:
        _preview_2x2(im, Path(args.preview))

    if args.report:
        print(f"input_size   {raw_size} -> 1024x1024")
        print(f"target       {args.kind} L{TARGET_L[args.kind]:.1f}")
        print(f"mean_luma    {l0:.1f} -> {l1:.1f}")
        print(f"mean_sat     {s0:.1f} -> {s1:.1f}")
        print(f"edge_diff    lr={seams['lr']:.1f} tb={seams['tb']:.1f}  (<8 可用；>8 靠 4 向随机铺贴)")
        print(f"output       {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())