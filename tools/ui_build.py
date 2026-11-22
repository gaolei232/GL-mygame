#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ui_build.py —— 九宫格 UI 精确生成器

为什么 UI 不能直接拿 AI 出图进引擎（第 5 批实测结论）：
  九宫格要成立，四边距 / 圆角半径 / 内描边宽度必须**像素级严格一致**，且
  可拉伸区的像素必须**完全均匀**（方差为 0）。生成模型做不到这两条：
  同一张图里的四个材质块，圆角与描边肉眼看都不一样，直接切九宫格拉伸必出接缝。

所以本批走双轨：
  · 几何（圆角、描边、边距、1px alpha 边）—— 本脚本逐像素精确绘制，4x 超采样
  · 材质（磨损、烟熏、划痕）        —— 从 art/raw/ui 的 AI 材质图取纹理，
                                       只铺在四角 32px 区块内，且径向淡出到区块边界
  边缘中段与中心保持纯色，保证拉伸不变形 —— 这是九宫格唯一正确的做法。

用法：
  python ui_build.py                       # 生成全部
  python ui_build.py --outdir D:/x/ui      # 指定输出
  python ui_build.py --verify              # 只跑验收，不写文件

输出全部 RGBA，几何全在整数像素上。
依赖：pillow
"""

from __future__ import annotations

import argparse
import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

# ---------------- 色板（与 ui/hud.gd 对齐） ----------------
INK = (15, 18, 23, 255)          # #0F1217 面板底
INK_DEEP = (10, 13, 17, 255)     # 条槽更暗
PLATE = (26, 31, 38, 255)        # #1A1F26 板面亮面
STROKE = (42, 48, 56, 255)       # #2A3038 内描边
BTN = (58, 66, 76, 255)          # #3A424C 按钮面
BTN_HI = (70, 79, 91, 255)       # 按钮上半略亮
EMBER = (232, 131, 74, 255)      # #E8834A 强调
OCHRE = (194, 162, 119, 255)     # #C2A277 夯土
OCHRE_D = (138, 111, 82, 255)    # #8A6F52 夯土暗
IRON = (183, 195, 207, 255)      # #B7C3CF
PAPER = (235, 240, 247, 255)     # #EBF0F7
RED = (217, 72, 47, 255)         # #D9482F

S = 4  # 超采样倍率


def q(v: float) -> int:
    return int(round(v * S))


def new(w: int, h: int) -> Image.Image:
    return Image.new("RGBA", (q(w), q(h)), (0, 0, 0, 0))


def down(im: Image.Image, w: int, h: int) -> Image.Image:
    return im.resize((w, h), Image.LANCZOS)


def rrect_mask(w: int, h: int, r: float) -> Image.Image:
    m = Image.new("L", (q(w), q(h)), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, q(w) - 1, q(h) - 1], radius=q(r), fill=255)
    return m


def rrect(img: Image.Image, box, r: float, fill=None, outline=None, width: float = 1) -> None:
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([q(box[0]), q(box[1]), q(box[2]), q(box[3])],
                        radius=q(r), fill=fill, outline=outline,
                        width=max(1, q(width)) if outline else 0)


def flat(img: Image.Image, color) -> Image.Image:
    layer = Image.new("RGBA", img.size, color)
    return layer


# ---------------- 材质纹理（来自 AI 材质图） ----------------

_TEX_CACHE: dict[str, Image.Image | None] = {}


def load_tex(raw_dir: Path) -> Image.Image | None:
    """取 AI 材质图里左上那块铁板的内部区域作为磨损纹理。"""
    key = str(raw_dir)
    if key in _TEX_CACHE:
        return _TEX_CACHE[key]
    cands = sorted(raw_dir.glob("*.png")) if raw_dir.exists() else []
    tex = None
    if cands:
        src = Image.open(cands[0]).convert("RGB")
        w, h = src.size
        # 左上象限内部，避开铆钉与边缘
        crop = src.crop((int(w * 0.16), int(h * 0.16), int(w * 0.44), int(h * 0.44)))
        tex = crop.resize((160, 160), Image.LANCZOS).convert("L")
    _TEX_CACHE[key] = tex
    return tex


def proc_wear(B: int, seed: int, amp: float) -> list[list[int]]:
    """程序化磨损：返回 B×B 的有符号明度偏移表（纯 Python，不依赖 numpy）。

    为什么放弃 AI 纹理：实测 AI 出的铁板中段明度 std 只有 4.2（铆钉那 174 的高光不算
    纹理），缩到 32px 角块后偏移不到 ±2，肉眼完全看不出四角有磨损 —— 等于没做。
    程序化可控：划痕方向、烟熏浓度、锈斑密度都能直接调，且固定 seed 可复现。

    三类痕迹分开生成，对应真实铁板的三种损伤：
      · 划痕 scratch —— 细长直线，方向随机，受光侧提亮、背光侧压暗（一明一暗成对出现）
      · 烟熏 soot    —— 低频团块，只压暗，集中在外角
      · 锈斑 rust    —— 稀疏小点，提亮（锈是浅褐色，在近黑底上是亮点）
    """
    rnd = random.Random(seed)
    off = [[0.0] * B for _ in range(B)]

    # 低频烟熏：几团高斯，中心偏外角
    for _ in range(3):
        cx = rnd.uniform(-0.1, 0.55) * B
        cy = rnd.uniform(-0.1, 0.55) * B
        sg = rnd.uniform(0.22, 0.42) * B
        amt = rnd.uniform(0.7, 1.0)
        for y in range(B):
            dy = (y - cy) / sg
            for x in range(B):
                dx = (x - cx) / sg
                g = math.exp(-(dx * dx + dy * dy) * 0.5)
                if g > 0.01:
                    off[y][x] -= amp * 0.55 * amt * g

    # 细长划痕
    for _ in range(5):
        a = rnd.uniform(0, math.pi)
        L = rnd.uniform(0.28, 0.62) * B
        x0 = rnd.uniform(0.05, 0.75) * B
        y0 = rnd.uniform(0.05, 0.75) * B
        dx, dy = math.cos(a), math.sin(a)
        thick = rnd.choice((0.8, 1.0, 1.2))
        bright = rnd.uniform(0.55, 1.0)
        steps = int(L * 2)
        for i in range(steps):
            t = i / float(steps)
            px = x0 + dx * L * t
            py = y0 + dy * L * t
            # 划痕本身提亮，紧邻下方 1px 压暗（受光沟槽的读法）
            for oy, val in ((0.0, amp * bright), (thick, -amp * bright * 0.55)):
                for ox in (-0.5, 0.0, 0.5):
                    xi = int(px + ox)
                    yi = int(py + oy)
                    if 0 <= xi < B and 0 <= yi < B:
                        off[yi][xi] += val * (1.0 - abs(ox) * 0.6)

    # 锈斑
    for _ in range(14):
        cx = rnd.uniform(0, 1) * B
        cy = rnd.uniform(0, 1) * B
        r = rnd.uniform(0.6, 1.6)
        val = rnd.uniform(0.25, 0.7) * amp
        for y in range(max(0, int(cy - r - 1)), min(B, int(cy + r + 2))):
            for x in range(max(0, int(cx - r - 1)), min(B, int(cx + r + 2))):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    off[y][x] += val

    return off


def apply_wear(img: Image.Image, block: int, tex: Image.Image | None, strength: float = 0.5,
               base_col=INK, seed: int = 7) -> Image.Image:
    """把四角磨损叠到图上，保留原 alpha。

    v3 起改为**程序化双向明暗偏移**。两条历史教训：
      1. 乘算在深底上是死路 —— 面板 #0F1217 乘任何系数仍在 0–23，看不出磨损（v2 实测）。
      2. AI 纹理起伏不够 —— 铁板中段明度 std 仅 4.2，缩到 32px 角块后偏移 ±2，肉眼不可见。
    现在：base + offset，offset 含划痕（成对明暗）、烟熏（只压暗）、锈斑（提亮）。
    衰减 falloff = (1-x/B)^1.15 * (1-y/B)^1.15，在角块两条内边界严格为 0，
    区块尺寸严格等于九宫格边距，绝不越界（v1 越界后中心区实测 127 种颜色）。
    """
    W = img.size[0] // S
    H = img.size[1] // S
    B = block
    amp = 30.0 * strength
    base = proc_wear(B, seed, amp)

    out = img.copy()
    op = out.load()
    for idx, (cx0, cy0) in enumerate(((0, 0), (W - B, 0), (0, H - B), (W - B, H - B))):
        # 每个角各自生成一套痕迹（不同 seed），并朝外角衰减
        off = proc_wear(B, seed * 31 + idx * 977, amp)
        for y in range(B):
            wy = (1.0 - y / float(B)) ** 1.15
            gy = cy0 + (y if idx < 2 else B - 1 - y)
            for x in range(B):
                wv = wy * ((1.0 - x / float(B)) ** 1.15)
                d = int(off[y][x] * wv)
                if d == 0:
                    continue
                gx = cx0 + (x if idx in (0, 2) else B - 1 - x)
                for sy in range(S):
                    for sx in range(S):
                        px, py = gx * S + sx, gy * S + sy
                        r, g, b, a = op[px, py]
                        if a == 0:
                            continue
                        op[px, py] = (max(0, min(255, r + d)), max(0, min(255, g + d)),
                                      max(0, min(255, b + d)), a)
    return out


def rivet(img: Image.Image, cx: float, cy: float, r: float = 3.0) -> None:
    d = ImageDraw.Draw(img)
    # 外圈暗
    d.ellipse([q(cx - r), q(cy - r), q(cx + r), q(cy + r)], fill=STROKE)
    # 左上受光
    d.ellipse([q(cx - r + 0.7), q(cy - r + 0.7), q(cx + r - 1.4), q(cy + r - 1.4)], fill=IRON)
    d.ellipse([q(cx - r + 1.4), q(cy - r + 1.4), q(cx + r - 2.2), q(cy + r - 2.2)], fill=STROKE)


# ---------------- 各资产 ----------------

def build_panel(w: int, h: int, radius: float, border: int, tex, wear_strength: float = 0.55,
                with_rivets: bool = True) -> Image.Image:
    """九宫格面板：细节只在四角 border×border 区块内，其余纯色。"""
    img = new(w, h)
    mask = rrect_mask(w, h, radius)
    img.paste(flat(img, INK), (0, 0), mask)
    img = apply_wear(img, border, tex, wear_strength)
    img.putalpha(mask)
    # 内描边：贴边 4px 处，2px 宽
    st = new(w, h)
    rrect(st, (4, 4, w - 4, h - 4), max(2, radius - 4), outline=STROKE, width=2)
    img = Image.alpha_composite(img, st)
    if with_rivets:
        inset = border * 0.55
        for cx, cy in ((inset, inset), (w - inset, inset), (inset, h - inset), (w - inset, h - inset)):
            rivet(img, cx, cy, r=min(3.4, border * 0.11))
    img.putalpha(mask)
    return img


def build_button(w: int, h: int, state: str, tex) -> Image.Image:
    radius, border = 20, 24
    img = new(w, h)
    mask = rrect_mask(w, h, radius)
    fill = new(w, h)
    off = 2 if state == "pressed" else 0
    if state == "pressed":
        rrect(fill, (0, off, w, h + off), radius,
              fill=tuple(int(c * 0.85) for c in BTN[:3]) + (255,))
    elif state == "disabled":
        rrect(fill, (0, 0, w, h), radius, fill=(56, 59, 63, 255))
    else:
        rrect(fill, (0, 0, w, h), radius, fill=BTN)
    img.paste(fill, (0, 0), mask)
    img = apply_wear(img, border, tex, 0.35, BTN)
    img.putalpha(mask)
    # 亮面/描边一律做成「等宽边框元素」，不画横向色带。
    # v1 用了一条横向 2 阶色块做"上面略亮"，导致左右边缘条带在垂直拉伸时被拉成模糊带，
    # 验收直接测出 left=9 / right=11 种颜色。九宫格里任何横向色带都必须落在角块内。
    st = new(w, h)
    rrect(st, (3, 3 + off, w - 3, h - 3 + off), radius - 3, outline=STROKE, width=2)
    d = ImageDraw.Draw(st)
    d.line([(q(4), q(4 + off)), (q(w - 4), q(4 + off))],
           fill=(255, 255, 255, 20), width=q(1))
    img = Image.alpha_composite(img, st)
    if state != "disabled":
        bar = new(w, h)
        rrect(bar, (5, 7 + off, 9, h - 7 + off), 2, fill=EMBER)
        img = Image.alpha_composite(img, bar)
    if state == "disabled":
        hatch = new(w, h)
        d = ImageDraw.Draw(hatch)
        for i in range(-q(h), q(w) + q(h), q(14)):
            d.line([(i, 0), (i + q(h), q(h))], fill=(255, 255, 255, 26), width=q(1.5))
        hatch.putalpha(Image.composite(hatch.split()[3], Image.new("L", hatch.size, 0), mask))
        img = Image.alpha_composite(img, hatch)
    img.putalpha(mask)
    return img


def build_bar(w: int, h: int, kind: str) -> Image.Image:
    """血条三件套。frame **必须中空** —— v1 画成实心板，叠上去直接把填充盖死了。"""
    img = new(w, h)
    radius = h / 2.0
    if kind == "frame":
        # 只画 2px 环，内部全透明。描边用 IRON 而不是 STROKE：
        # STROKE #2A3038 在 #0F1217 底上对比度只有 1.6:1，缩到 1x 就看不见了，
        # 血条会读成"没有框"。改用 #B7C3CF 的 45% 混合色作为金属亮边。
        d = ImageDraw.Draw(img)
        edge = tuple(int(STROKE[i] + (IRON[i] - STROKE[i]) * 0.62) for i in range(3)) + (255,)
        d.rounded_rectangle([q(1), q(1), q(w - 1), q(h - 1)], radius=q(radius),
                            outline=edge, width=q(2))
        # 上缘一道 1px 高光，暗示金属边框厚度
        d.arc([q(1), q(1), q(w - 1), q(h - 1)], 190, 350, fill=(255, 255, 255, 70), width=q(1))
        return img
    mask = rrect_mask(w, h, radius)
    if kind == "bg":
        img.paste(flat(img, INK_DEEP), (0, 0), mask)
    else:  # fill：纯白，交给代码 modulate 染色
        img.paste(flat(img, (255, 255, 255, 255)), (0, 0), mask)
    img.putalpha(mask)
    return img


def cell_polygon(w: int, h: int, notch: bool) -> list[tuple[float, float]]:
    """碎裂砖格轮廓：切角 + 可选顶部三角缺口。"""
    c = min(w, h) * 0.16
    pts = [(c, 0), (w - c, 0), (w, c * 0.8), (w, h - c * 0.5), (w - c * 0.7, h),
           (c * 0.6, h), (0, h - c * 0.6), (0, c * 0.9)]
    if notch:
        nx = w * 0.5
        nw = w * 0.22
        nd = h * 0.34
        pts = [(c, 0), (nx - nw, 0), (nx, nd), (nx + nw, 0), (w - c, 0),
               (w, c * 0.8), (w, h - c * 0.5), (w - c * 0.7, h),
               (c * 0.6, h), (0, h - c * 0.6), (0, c * 0.9)]
    return [(x * S, y * S) for x, y in pts]


def build_wall_cell(w: int, h: int, state: str) -> Image.Image:
    img = new(w, h)
    d = ImageDraw.Draw(img)
    if state == "breached":
        d.polygon(cell_polygon(w, h, True), fill=INK_DEEP)
        d.line(cell_polygon(w, h, True) + [cell_polygon(w, h, True)[0]],
               fill=(*OCHRE_D[:3], 170), width=q(1.6), joint="curve")
        return img
    d.polygon(cell_polygon(w, h, False), fill=OCHRE)
    # 底部与右侧压暗做厚度
    d.polygon([(0, h), (w, h), (w, h - h * 0.22), (w - w * 0.05, h - h * 0.18),
               (w * 0.05, h - h * 0.18)], fill=OCHRE_D)
    d.line(cell_polygon(w, h, False) + [cell_polygon(w, h, False)[0]],
           fill=(*OCHRE_D[:3], 255), width=q(1.2), joint="curve")
    if state == "damaged":
        # 裂纹：从上缘缺口处向下分叉，形状而非仅靠颜色
        d.line([(q(w * 0.5), q(h * 0.02)), (q(w * 0.42), q(h * 0.45)), (q(w * 0.55), q(h * 0.95))],
               fill=(72, 58, 42, 255), width=q(1.6))
        d.line([(q(w * 0.42), q(h * 0.45)), (q(w * 0.24), q(h * 0.68))],
               fill=(72, 58, 42, 255), width=q(1.2))
        # 右上缺角
        d.polygon([(q(w), q(h * 0.0)), (q(w - w * 0.26), q(0)), (q(w), q(h * 0.34))],
                  fill=(0, 0, 0, 0))
    return img


def build_slot(w: int, h: int, tex) -> Image.Image:
    radius = 6
    img = new(w, h)
    mask = rrect_mask(w, h, radius)
    img.paste(flat(img, INK), (0, 0), mask)
    img = apply_wear(img, 24, tex, 0.4)
    img.putalpha(mask)
    st = new(w, h)
    rrect(st, (0.5, 0.5, w - 0.5, h - 0.5), radius, outline=STROKE, width=1)
    rrect(st, (4.5, 4.5, w - 4.5, h - 4.5), radius - 2, outline=(255, 255, 255, 16), width=1)
    img = Image.alpha_composite(img, st)
    # 四角短刻线（不做铆钉，避免与面板抢)
    t = new(w, h)
    d = ImageDraw.Draw(t)
    L = 10
    for sx, sy, dx, dy in ((0, 0, 1, 1), (1, 0, -1, 1), (0, 1, 1, -1), (1, 1, -1, -1)):
        x = 3 if sx == 0 else w - 3
        y = 3 if sy == 0 else h - 3
        d.line([(q(x), q(y)), (q(x + dx * L), q(y))], fill=STROKE, width=q(1.5))
        d.line([(q(x), q(y)), (q(x), q(y + dy * L))], fill=STROKE, width=q(1.5))
    img = Image.alpha_composite(img, t)
    img.putalpha(mask)
    return img


def build_card(w: int, h: int, border: int, tex) -> Image.Image:
    """奖励卡框：**灰度底**，四主题靠代码 modulate 染色，一套图四用。"""
    radius = 10
    img = new(w, h)
    mask = rrect_mask(w, h, radius)
    g = (200, 200, 200, 255)
    g_d = (150, 150, 150, 255)
    gi = (60, 60, 60, 255)
    img.paste(flat(img, g), (0, 0), mask)
    # 内部镂空：**内圆角必须为 0**。v1 用了 radius-4=6，内圆角的弧线会越过 20px
    # 角块边界（实测在 22px 处出现 5 种杂色），越过的那几像素就落在可拉伸区里。
    # 卡框的"外圆内方"是九宫格的基本形态，不是妥协。
    inner = new(w, h)
    rrect(inner, (border, border, w - border, h - border), 0, fill=gi)
    img = Image.alpha_composite(img, inner)
    img = apply_wear(img, border, tex, 0.3, g)
    img.putalpha(mask)
    st = new(w, h)
    rrect(st, (border - 1, border - 1, w - border + 1, h - border + 1), 0, outline=g_d, width=1)
    rrect(st, (2, 2, w - 2, h - 2), radius - 1, outline=g_d, width=2)
    img = Image.alpha_composite(img, st)
    for cx, cy in ((border * 0.5 + 3, border * 0.5 + 3), (w - border * 0.5 - 3, border * 0.5 + 3),
                   (border * 0.5 + 3, h - border * 0.5 - 3), (w - border * 0.5 - 3, h - border * 0.5 - 3)):
        d = ImageDraw.Draw(img)
        d.ellipse([q(cx - 2), q(cy - 2), q(cx + 2), q(cy + 2)], fill=g_d)
    img.putalpha(mask)
    return img


def build_crosshair(size: int) -> Image.Image:
    """4 段开口圆环 + 中心点。开口对应散射角（0.06 rad ≈ 3.4°，视觉上放大到 24°），不用红色。

    几何约定（v1 画反了）：
      · 弧段位于**上下左右**，缺口落在**对角线** —— 这是准星的通用读法，
        玩家视线沿十字方向，"十字通、斜角断"才不挡视线。v1 让缺口正对四个方向、
        短刺也正对四个方向，读起来像一个"十字架靶"而不是准星。
      · 短刺从弧段内侧向内指，长度不超过半径的 40%，不与中心点相连。
    """
    img = new(size, size)
    d = ImageDraw.Draw(img)
    c = size / 2.0
    r = size * 0.36
    gap_deg = 24.0                      # 对角线处的缺口角度
    col = (*PAPER[:3], 235)
    box = [q(c - r), q(c - r), q(c + r), q(c + r)]
    for k in range(4):
        ctr = k * 90                    # 弧段中心在 0/90/180/270
        d.arc(box, ctr - (90 - gap_deg) / 2, ctr + (90 - gap_deg) / 2, fill=col, width=q(2))
    # 四向短刺：从弧内侧向内，留 8% 空隙不与圆心相连
    for k in range(4):
        a = math.radians(k * 90)
        d.line([(q(c + math.cos(a) * r * 0.74), q(c + math.sin(a) * r * 0.74)),
                (q(c + math.cos(a) * r * 0.46), q(c + math.sin(a) * r * 0.46))],
               fill=(*PAPER[:3], 175), width=q(1.4))
    d.ellipse([q(c - 1), q(c - 1), q(c + 1), q(c + 1)], fill=col)
    return img


def build_danger_edge(w: int, h: int, band: int, peak: float = 0.35) -> Image.Image:
    """四边向内脉动条：边缘峰值 alpha=peak*255，向内线性衰减到 0。不做圆角。"""
    img = Image.new("RGBA", (q(w), q(h)), (0, 0, 0, 0))
    px = img.load()
    for y in range(h):
        for x in range(w):
            dmin = min(x, y, w - 1 - x, h - 1 - y)
            if dmin >= band:
                continue
            t = 1.0 - dmin / float(band)
            a = int(peak * 255 * (t ** 1.6))
            if a <= 0:
                continue
            for dy in range(S):
                for dx in range(S):
                    px[x * S + dx, y * S + dy] = (RED[0], RED[1], RED[2], a)
    return img


def build_chevron(size: int) -> Image.Image:
    img = new(size, size)
    d = ImageDraw.Draw(img)
    m = size * 0.5
    d.polygon([(q(m), q(size * 0.12)), (q(size * 0.9), q(size * 0.84)),
               (q(m), q(size * 0.62)), (q(size * 0.1), q(size * 0.84))], fill=RED)
    return img


# ---------------- 验收 ----------------

def verify_flat(img: Image.Image, border: int, label: str) -> dict:
    """九宫格的硬判据：可拉伸区方差必须为 0。"""
    w, h = img.size
    rgb = img.convert("RGB")
    px = rgb.load()
    # 中心区（避开四角与四边中段）
    cx0, cy0 = border, border
    cx1, cy1 = w - border, h - border
    vals = set()
    for y in range(cy0 + 2, cy1 - 2):
        for x in range(cx0 + 2, cx1 - 2):
            vals.add(px[x, y])
    # 四边中段的中间 1/3（会被单向拉伸）
    edges = {
        "top": [(x, border // 2) for x in range(w // 3, w * 2 // 3)],
        "bottom": [(x, h - border // 2) for x in range(w // 3, w * 2 // 3)],
        "left": [(border // 2, y) for y in range(h // 3, h * 2 // 3)],
        "right": [(w - border // 2, y) for y in range(h // 3, h * 2 // 3)],
    }
    edge_uniq = {k: len({px[x, y] for x, y in v}) for k, v in edges.items()}
    alpha = img.split()[3]
    a_min, a_max = alpha.getextrema()
    return {
        "name": label,
        "size": f"{w}x{h}",
        "center_unique_colors": len(vals),
        "edge_unique": edge_uniq,
        "alpha_range": (a_min, a_max),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", default="art/assets/ui")
    ap.add_argument("--raw", default="art/raw/ui")
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args()

    root = Path(__file__).resolve().parent.parent
    outdir = root / args.outdir
    outdir.mkdir(parents=True, exist_ok=True)
    tex = load_tex(root / args.raw)

    made: list[tuple[str, Image.Image]] = []

    # 1 面板 512² 边距 32 圆角 20
    p = down(build_panel(512, 512, 20, 32, tex), 512, 512)
    made.append(("ui_panel_bastion_normal_v1.png", p))

    # 2 按钮 240×88 三态，边距 24 圆角 20
    for st in ("normal", "pressed", "disabled"):
        b = down(build_button(240, 88, st, tex), 240, 88)
        made.append((f"ui_btn_primary_{st}_v1.png", b))

    # 3 血条三件套 380×16
    for kind in ("frame", "bg", "fill"):
        bar = down(build_bar(380, 16, kind), 380, 16)
        made.append((f"ui_bar_{kind}_v1.png", bar))

    # 4 城墙 7 格：格子本体出 48 与 24 两档（24 仅存在性证明）
    for state in ("intact", "damaged", "breached"):
        c = down(build_wall_cell(48, 36, state), 48, 36)
        made.append((f"ui_wall_cell_{state}_48.png", c))
        c24 = down(build_wall_cell(48, 36, state), 24, 18)
        made.append((f"ui_wall_cell_{state}_24.png", c24))
    # 组装条：7 格，gap 4（48 档）/ gap 2（24 档）
    for cw, ch, gap in ((48, 36, 4), (24, 18, 2)):
        strip = Image.new("RGBA", (cw * 7 + gap * 6, ch), (0, 0, 0, 0))
        for i in range(7):
            strip.alpha_composite(Image.open(outdir / f"ui_wall_cell_intact_{cw}.png")
                                  if (outdir / f"ui_wall_cell_intact_{cw}.png").exists()
                                  else down(build_wall_cell(48, 36, "intact"), cw, ch),
                                  (i * (cw + gap), 0))
        made.append((f"ui_wall_gauge_7seg_{cw * 7 + gap * 6}.png", strip))

    # 5 奖励卡 220×300 边距 20（灰度）
    made.append(("ui_reward_card_frame_v1.png", down(build_card(220, 300, 20, tex), 220, 300)))
    # 6 槽位 120×120
    made.append(("ui_slot_frame_v1.png", down(build_slot(120, 120, tex), 120, 120)))
    # 7 提示条 512×48 边距 12
    # 原为 512×40 / 边距 16：上下各 16 之后只剩 8px 可拉伸带，验收实测左右边缘出现
    # 2 种颜色 —— 40 高的横条根本容不下 16px 九宫格边距。改为 48 高 / 12 边距。
    made.append(("ui_notice_ribbon_v1.png", down(build_panel(512, 48, 6, 12, tex, 0.35, False), 512, 48)))
    # 8 准星 64²
    made.append(("ui_crosshair_v1.png", down(build_crosshair(64), 64, 64)))
    # 9 危险边缘 1280×720
    made.append(("ui_danger_edge_v1.png", down(build_danger_edge(1280, 720, 90), 1280, 720)))
    made.append(("ui_danger_chevron_v1.png", down(build_chevron(48), 48, 48)))

    if not args.verify:
        for name, im in made:
            if im.mode != "RGBA":
                im = im.convert("RGBA")
            im.save(outdir / name)
        print(f"写好 {len(made)} 个文件 → {outdir}")

    # 验收
    print("\n=== 九宫格可拉伸区均匀性（unique colors 必须为 1） ===")
    checks = [
        (p, 32, "ui_panel_bastion_normal_v1"),
        (dict(made)[f"ui_btn_primary_normal_v1.png"], 24, "ui_btn_primary_normal_v1"),
        (dict(made)[f"ui_reward_card_frame_v1.png"], 20, "ui_reward_card_frame_v1"),
        (dict(made)["ui_notice_ribbon_v1.png"], 12, "ui_notice_ribbon_v1"),
    ]
    bad = 0
    for im, b, name in checks:
        r = verify_flat(im, b, name)
        ok = r["center_unique_colors"] == 1 and max(r["edge_unique"].values()) == 1
        bad += 0 if ok else 1
        print(f"{'OK ' if ok else 'FAIL'} {name:38s} {r['size']:9s} "
              f"center={r['center_unique_colors']:3d} edges={r['edge_unique']} alpha={r['alpha_range']}")
    print(f"\n不均匀项：{bad}")


if __name__ == "__main__":
    main()