#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""icon_norm.py —— 图标/小物件归一化：抠底 → 自动分件 → 统一视觉重量 → 多档输出

为什么不是简单切格子：
  1×3 几何均分会把主体切断（实测弩只剩一条 2px 边线）。
  按「不透明像素面积」归一化，而不是按包围盒等宽——否则细长的刀会比方形的砖
  大一圈，一套图标看着不像一套。

两种分件方式：
  --mode auto（默认）  整张图抠底后按连通域找 N 个主体，按行优先排序
  --mode grid          按 cols×rows 几何均分（仅在排布极规整时用）

用法：
  python icon_norm.py sheet.png --names a,b,c --outdir out
  python icon_norm.py sheet.png --names a,b,c --outdir out --area 0.30 --keymode light

输出：每个 N 份 —— _512 母版 / _192 / _96，RGBA、居中、视觉重量一致。

依赖：pillow
"""

from __future__ import annotations

import argparse
import sys
from collections import deque
from pathlib import Path

try:
    from PIL import Image, ImageFilter
except ImportError:
    sys.stderr.write("需要 pillow：pip install pillow\n")
    raise SystemExit(1)


# ---------- 抠底 ----------

def keyout(im: Image.Image, mode: str, tol: int, lthr: int, sthr: int) -> Image.Image:
    """从四边泛洪去底。

    white：与纯白欧氏距离 <= tol 视为底
    light：亮度 >= lthr 且饱和度 <= sthr 视为底（可一次带走落地投影）
    """
    rgb = im.convert("RGB")
    w, h = rgb.size
    px = rgb.load()
    tol2 = tol * tol
    near = bytearray(w * h)
    for y in range(h):
        row = y * w
        for x in range(w):
            r, g, b = px[x, y]
            if mode == "light":
                mx, mn = max(r, g, b), min(r, g, b)
                lum = 0.299 * r + 0.587 * g + 0.114 * b
                sat = 0.0 if mx == 0 else (mx - mn) / mx * 100
                if lum >= lthr and sat <= sthr:
                    near[row + x] = 1
            else:
                if (255 - r) ** 2 + (255 - g) ** 2 + (255 - b) ** 2 <= tol2:
                    near[row + x] = 1

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

    alpha = Image.new("L", (w, h), 255)
    ap = alpha.load()
    for y in range(h):
        row = y * w
        for x in range(w):
            if outside[row + x]:
                ap[x, y] = 0
    out = rgb.convert("RGBA")
    out.putalpha(alpha)
    return out


# ---------- 自动分件 ----------

def find_objects(im: Image.Image, dilate_px: int = 60, min_area_ratio: float = 0.0015):
    """按 alpha 连通域找主体，返回按行优先排序的 bbox 列表。"""
    w, h = im.size
    a = im.getchannel("A")
    # 降采样后再膨胀/连通，速度快很多，坐标最后 ×4 还原
    k = 4
    small = a.resize((max(1, w // k), max(1, h // k)), Image.BOX)
    bw, bh = small.size
    binm = small.point(lambda v: 255 if v > 16 else 0)
    binm = binm.filter(ImageFilter.MaxFilter(2 * (dilate_px // k // 2) + 1))
    px = binm.load()

    seen = [[False] * bw for _ in range(bh)]
    boxes = []
    total = 0
    for y in range(bh):
        for x in range(bw):
            if px[x, y] == 0 or seen[y][x]:
                continue
            q = deque([(x, y)])
            seen[y][x] = True
            x0 = x1 = x
            y0 = y1 = y
            cnt = 0
            while q:
                cx, cy = q.popleft()
                cnt += 1
                x0, x1 = min(x0, cx), max(x1, cx)
                y0, y1 = min(y0, cy), max(y1, cy)
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < bw and 0 <= ny < bh and px[nx, ny] and not seen[ny][nx]:
                        seen[ny][nx] = True
                        q.append((nx, ny))
            total += cnt
            # 用原图 alpha 收紧缩放后的框，避免膨胀带来的外扩
            fx0, fy0, fx1, fy1 = x0 * k, y0 * k, min(w, (x1 + 1) * k), min(h, (y1 + 1) * k)
            sub = im.crop((fx0, fy0, fx1, fy1))
            bb = sub.getbbox()
            if bb:
                boxes.append((fx0 + bb[0], fy0 + bb[1], fx0 + bb[2], fy0 + bb[3], cnt))

    boxes = [b for b in boxes if b[4] >= total * min_area_ratio]
    # 行优先：先按 y 分带，再按 x
    boxes.sort(key=lambda b: (round((b[1] + b[3]) / 2 / max(1, h // 3)), b[0]))
    return [(b[0], b[1], b[2], b[3]) for b in boxes]


# ---------- 归一化 ----------

def norm_area(im: Image.Image, canvas: int, target_area: float = 0.30,
              max_side: float = 0.92) -> Image.Image:
    """按不透明像素面积归一化视觉重量，再按 max_side 夹紧。"""
    bb = im.getbbox()
    if bb:
        im = im.crop(bb)
    w, h = im.size
    a = im.getchannel("A").point(lambda v: 255 if v > 16 else 0)
    opaque = sum(1 for v in a.tobytes() if v)
    if opaque == 0:
        return Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))

    s = (target_area * canvas * canvas / opaque) ** 0.5
    s = min(s, max_side * canvas / max(w, h))
    nw, nh = max(1, int(round(w * s))), max(1, int(round(h * s)))
    im = im.resize((nw, nh), Image.LANCZOS)
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    out.paste(im, ((canvas - nw) // 2, (canvas - nh) // 2), im)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("img")
    ap.add_argument("--names", required=True, help="逗号分隔，按行优先顺序")
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--mode", choices=("auto", "grid"), default="auto")
    ap.add_argument("--grid", default="1x1", help="grid 模式下的切格，如 2x2")
    ap.add_argument("--keymode", choices=("white", "light"), default="white")
    ap.add_argument("--tol", type=int, default=22)
    ap.add_argument("--lthr", type=int, default=200)
    ap.add_argument("--sthr", type=int, default=16)
    ap.add_argument("--area", type=float, default=0.30,
                    help="主体不透明像素占画布比例，默认 0.30")
    ap.add_argument("--dilate", type=int, default=60, help="分件前的膨胀像素，合并邻近碎片")
    args = ap.parse_args()

    src = Path(args.img)
    if not src.exists():
        sys.stderr.write(f"文件不存在：{src}\n")
        return 1

    names = [n.strip() for n in args.names.split(",") if n.strip()]
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    sheet = Image.open(src).convert("RGB")
    cut = keyout(sheet, args.keymode, args.tol, args.lthr, args.sthr)

    if args.mode == "grid":
        cols, rows = (int(v) for v in args.grid.lower().split("x"))
        if len(names) != cols * rows:
            sys.stderr.write(f"--names {len(names)} 与格数 {cols}x{rows} 不符\n")
            return 2
        W, H = cut.size
        cw, ch = W // cols, H // rows
        pieces = [cut.crop((c * cw, r * ch, (c + 1) * cw, (r + 1) * ch))
                  for r in range(rows) for c in range(cols)]
    else:
        boxes = find_objects(cut, dilate_px=args.dilate)
        if len(boxes) != len(names):
            sys.stderr.write(
                f"自动分件得到 {len(boxes)} 个主体，与 --names {len(names)} 不符。\n"
                f"框：{boxes}\n调 --dilate 或改用 --mode grid。\n")
            return 3
        pieces = [cut.crop(b) for b in boxes]

    for name, piece in zip(names, pieces):
        for canvas, suffix in ((512, "_512"), (192, "_192"), (96, "_96")):
            norm_area(piece, canvas, args.area).save(outdir / f"{name}{suffix}.png")
        print(f"✅ {name}")

    print(f"输出目录：{outdir}（_512 / _192 / _96，主体面积 {int(args.area*100)}%）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
