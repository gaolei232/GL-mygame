#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""keyout_flood.py —— 只抠外轮廓的抠图工具（深色资产专用）

与 art_asset_tools.py 的 keyout 的区别：
  keyout     = 全图颜色匹配 -> 主体暗部与底色接近时，会在主体内部打出空洞
  keyout_flood = 从画面四边泛洪 -> 只有"与边界连通"的底色像素会被删，主体内部
                 无论多暗都不会被误删

适用：低模深色角色 / 怪物 / 城墙等"主体暗部与背景同明度区间"的资产。

用法：
  python keyout_flood.py <img> [--bg #1F2227] [--tol 20] [--feather 0] [--out out.png]
  --bg       底色，不给则由四角自动采样
  --tol      颜色容差（欧氏距离，0-441），深色底建议 14-24
  --feather  边缘羽化像素，低模硬边资产建议 0
  --report   打印透明比例与内暗部保护数

依赖：pillow
"""

from __future__ import annotations

import argparse
import sys
from collections import deque
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.stderr.write("需要 pillow：pip install pillow\n")
    raise SystemExit(1)


def parse_hex(s: str) -> tuple[int, int, int]:
    s = s.strip().lstrip("#")
    if len(s) != 6:
        raise ValueError(f"色值格式应为 #RRGGBB：{s}")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def sample_bg(im: Image.Image) -> tuple[int, int, int]:
    """四角 4x4 区域取中位数，避开单个像素噪点。"""
    w, h = im.size
    px = im.load()
    vals = []
    for cx, cy in ((2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)):
        for dx in range(-1, 2):
            for dy in range(-1, 2):
                x = min(max(cx + dx, 0), w - 1)
                y = min(max(cy + dy, 0), h - 1)
                vals.append(px[x, y])
    vals.sort(key=lambda c: c[0] + c[1] + c[2])
    return vals[len(vals) // 2]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("img")
    ap.add_argument("--bg", help="底色 #RRGGBB，缺省自动采样四角")
    ap.add_argument("--tol", type=int, default=20, help="颜色容差，默认 20")
    ap.add_argument("--feather", type=int, default=0, help="边缘羽化像素，默认 0")
    ap.add_argument("--out", help="输出路径，默认 <name>_flood.png")
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args()

    src = Path(args.img)
    if not src.exists():
        sys.stderr.write(f"文件不存在：{src}\n")
        return 1

    im = Image.open(src).convert("RGB")
    w, h = im.size
    bg = parse_hex(args.bg) if args.bg else sample_bg(im)
    tol2 = args.tol * args.tol

    px = im.load()
    # 1) 与底色的距离在容差内 -> 候选背景
    near = bytearray(w * h)
    for y in range(h):
        row = y * w
        for x in range(w):
            r, g, b = px[x, y]
            dr, dg, db = r - bg[0], g - bg[1], b - bg[2]
            if dr * dr + dg * dg + db * db <= tol2:
                near[row + x] = 1

    # 2) 只从四边泛洪，标记真正的外部背景
    outside = bytearray(w * h)
    q: deque[int] = deque()
    for x in range(w):
        for y in (0, h - 1):
            i = y * w + x
            if near[i] and not outside[i]:
                outside[i] = 1
                q.append(i)
    for y in range(h):
        for x in (0, w - 1):
            i = y * w + x
            if near[i] and not outside[i]:
                outside[i] = 1
                q.append(i)
    while q:
        i = q.popleft()
        y, x = divmod(i, w)
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h:
                j = ny * w + nx
                if near[j] and not outside[j]:
                    outside[j] = 1
                    q.append(j)

    # 3) 生成 alpha
    alpha = Image.new("L", (w, h), 255)
    ap_px = alpha.load()
    removed = 0
    for y in range(h):
        row = y * w
        for x in range(w):
            if outside[row + x]:
                ap_px[x, y] = 0
                removed += 1

    # 4) 边缘羽化（可选）：外部边缘内缩一圈给半透明
    if args.feather > 0:
        for _ in range(args.feather):
            edge = []
            for y in range(h):
                for x in range(w):
                    if outside[y * w + x]:
                        continue
                    for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                        if 0 <= nx < w and 0 <= ny < h and outside[ny * w + nx]:
                            edge.append((x, y))
                            break
            for x, y in edge:
                ap_px[x, y] = 160

    out = im.convert("RGBA")
    out.putalpha(alpha)

    # 5) 裁掉透明边，保留 2px 缓冲
    bbox = out.getbbox()
    if bbox:
        x0, y0, x1, y1 = bbox
        out = out.crop((max(x0 - 2, 0), max(y0 - 2, 0), min(x1 + 2, w), min(y1 + 2, h)))

    dst = Path(args.out) if args.out else src.with_name(src.stem + "_flood.png")
    out.save(dst)

    if args.report:
        kept = w * h - removed
        print(f"底色          #{bg[0]:02X}{bg[1]:02X}{bg[2]:02X}（容差 {args.tol}）")
        print(f"透明像素      {removed}  ({removed * 100 / (w * h):.1f}%)")
        print(f"保留主体像素  {kept}  ({kept * 100 / (w * h):.1f}%)")
        print("内部空洞      0（只删与边界连通区域，主体暗部受保护）")
    print(f"✅ 已输出：{dst}  {out.size[0]}x{out.size[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
