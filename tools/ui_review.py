#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ui_review.py —— 第 5 批 UI 审阅拼版 + 九宫格拉伸实测

为什么要做拉伸测试：均匀性（unique colors == 1）只证明"可拉伸区没有花纹"，
不证明"拉伸后不变形"。必须真的按 NinePatch 规则拉几个不同尺寸，肉眼确认角块没被
拉伸、描边宽度没变粗。这是九宫格最容易"数据全绿但看起来坏"的地方。
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
UI = ROOT / "art/assets/ui"
BG = (12, 15, 19, 255)
CARDBG = (20, 24, 30, 255)
C_TEXT = (235, 240, 247)
C_DIM = (150, 160, 175)
C_ACC = (232, 131, 74)


def font(sz: int):
    for p in ("C:/Windows/Fonts/msyhbd.ttc", "C:/Windows/Fonts/msyh.ttc", "C:/Windows/Fonts/simhei.ttf"):
        if Path(p).exists():
            return ImageFont.truetype(p, sz)
    return ImageFont.load_default()


def nine_slice(img: Image.Image, target_w: int, target_h: int, border) -> Image.Image:
    """标准 NinePatch：四角不缩放、四边单向拉伸、中心双向拉伸。"""
    if isinstance(border, int):
        bl = br = bt = bb = border
    else:
        bl, bt, br, bb = border
    w, h = img.size
    out = Image.new("RGBA", (target_w, target_h), (0, 0, 0, 0))
    cw = max(0, target_w - bl - br)
    ch = max(0, target_h - bt - bb)
    sw = max(1, w - bl - br)
    sh = max(1, h - bt - bb)
    # 四角
    for sx, sy, dx, dy in ((0, 0, 0, 0), (w - br, 0, target_w - br, 0),
                           (0, h - bb, 0, target_h - bb), (w - br, h - bb, target_w - br, target_h - bb)):
        cw_, ch_ = (bl if sx == 0 else br), (bt if sy == 0 else bb)
        out.paste(img.crop((sx, sy, sx + cw_, sy + ch_)), (dx, dy))
    # 四边
    top = img.crop((bl, 0, w - br, bt))
    bot = img.crop((bl, h - bb, w - br, h))
    left = img.crop((0, bt, bl, h - bb))
    right = img.crop((w - br, bt, w, h - bb))
    if cw > 0:
        out.paste(top.resize((cw, bt), Image.LANCZOS), (bl, 0))
        out.paste(bot.resize((cw, bb), Image.LANCZOS), (bl, target_h - bb))
    if ch > 0:
        out.paste(left.resize((bl, ch), Image.LANCZOS), (0, bt))
        out.paste(right.resize((br, ch), Image.LANCZOS), (target_w - br, bt))
    # 中心
    if cw > 0 and ch > 0:
        out.paste(img.crop((bl, bt, w - br, h - bb)).resize((cw, ch), Image.LANCZOS), (bl, bt))
    return out


def label(d: ImageDraw.ImageDraw, xy, text, sz=14, col=C_TEXT):
    d.text(xy, text, font=font(sz), fill=col)


def bar_fill(img: Image.Image, target_w: int, target_h: int) -> Image.Image:
    """血条填充专用缩放。

    为什么不能直接 nine_slice：填充是 h/2 半径的胶囊，两端端帽各占 8px，
    **宽度 < 16px 时两个端帽物理上放不下**。nine_slice 在这种情形下会把中心区
    压成负宽度、只剩两个错位的角块（实测 60px 宽那条出现断裂条纹）。
    规则：≥2r 用九宫格，<2r 直接按实际宽度重画圆头矩形。
    """
    radius = target_h // 2
    if target_w >= radius * 2:
        return nine_slice(img, target_w, target_h, radius)
    m = Image.new("L", (target_w, target_h), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, target_w - 1, target_h - 1],
                                        radius=max(1, min(radius, target_w // 2)), fill=255)
    out = Image.new("RGBA", (target_w, target_h), (255, 255, 255, 255))
    out.putalpha(m)
    return out


def main() -> None:
    W, H = 1500, 1400
    sheet = Image.new("RGBA", (W, H), BG)
    d = ImageDraw.Draw(sheet)

    # ---- 标题 ----
    label(d, (40, 26), "城墙尸潮 · 第 5 批 UI 审阅", 26, C_TEXT)
    label(d, (40, 60), "几何由 tools/ui_build.py 精确绘制（4x 超采样），AI 仅提供四角磨损纹理", 14, C_DIM)

    # ---- 1 面板 九宫格拉伸 ----
    y = 100
    label(d, (40, y), "1  面板 ui_panel_bastion_normal_v1 · 边距 32 / 圆角 20 / 内描边 2", 15, C_ACC)
    panel = Image.open(UI / "ui_panel_bastion_normal_v1.png")
    card = Image.new("RGBA", (1420, 300), CARDBG)
    cd = ImageDraw.Draw(card)
    for i, (tw, th) in enumerate(((200, 150), (340, 220), (420, 280))):
        p = nine_slice(panel, tw, th, 32)
        ox = 30 + i * 460
        card.alpha_composite(p, (ox, 60))
        cd.rectangle([ox, 60, ox + tw, 60 + th], outline=(80, 90, 100, 120))
        label(cd, (ox, 34), f"{tw}×{th}  ← 原图 512×512", 13, C_DIM)
    label(cd, (30, 10), "九宫格实拉：四角铆钉与描边保持原尺寸，只有中段被拉长", 13, C_DIM)
    sheet.alpha_composite(card, (40, y + 24))

    # ---- 2 按钮三态 ----
    y = 460
    label(d, (40, y), "2  主按钮 ui_btn_primary_*_v1 · 240×88 / 边距 24 / 圆角 20", 15, C_ACC)
    card = Image.new("RGBA", (1420, 190), CARDBG)
    cd = ImageDraw.Draw(card)
    for i, st in enumerate(("normal", "pressed", "disabled")):
        b = Image.open(UI / f"ui_btn_primary_{st}_v1.png")
        ox = 30 + i * 200
        card.alpha_composite(b, (ox, 46))
        label(cd, (ox, 24), st, 14, C_TEXT)
    # 拉伸 2 倍宽
    b = Image.open(UI / "ui_btn_primary_normal_v1.png")
    card.alpha_composite(nine_slice(b, 420, 88, 24), (660, 46))
    label(cd, (660, 24), "normal 拉到 420×88（文字放得下）", 14, C_TEXT)
    label(cd, (1110, 46), "强调条只在左边缘\n拉宽时不变粗\n禁用态加斜纹\n不靠颜色单独表达", 13, C_DIM)
    sheet.alpha_composite(card, (40, y + 24))

    # ---- 3 血条三件套 ----
    y = 680
    label(d, (40, y), "3  血条 ui_bar_frame / bg / fill · 380×16（frame 中空，fill 纯白由代码染色）", 15, C_ACC)
    card = Image.new("RGBA", (1420, 130), CARDBG)
    cd = ImageDraw.Draw(card)
    fr = Image.open(UI / "ui_bar_frame_v1.png")
    bg = Image.open(UI / "ui_bar_bg_v1.png")
    fl = Image.open(UI / "ui_bar_fill_v1.png")
    for i, (ratio, col, txt) in enumerate((
            (1.0, (102, 199, 245), "水晶 100%  #66C7F5"),
            (0.62, (102, 199, 245), "水晶 62%"),
            (0.28, (232, 131, 74), "生命 28% → 转 COL_WARN"))):
        ox, oy = 30 + i * 470, 56
        card.alpha_composite(bg, (ox, oy))
        fw = int(380 * ratio)
        if fw > 4:
            # fill 也走九宫格（边距 8 = 半径），否则缩短时圆角被压扁成直角
            f = bar_fill(fl, fw, 16)
            tint = Image.new("RGBA", f.size, col + (255,))
            tint.putalpha(f.split()[3])
            card.alpha_composite(tint, (ox, oy))
        card.alpha_composite(fr, (ox, oy))  # 边框压在最上，中空所以不漏填充
        label(cd, (ox, 34), txt, 13, C_DIM)
    label(cd, (30, 12), "填充两端圆角与框同心，缩短时不会露直角（fill 按 8px 边距九宫格缩放）", 13, C_DIM)
    sheet.alpha_composite(card, (40, y + 24))

    # ---- 4 城墙 7 格 ----
    y = 830
    label(d, (40, y), "4  城墙 7 格 24 格宽 + 三种格子状态（形状区分，不只靠颜色）", 15, C_ACC)
    card = Image.new("RGBA", (1420, 230), CARDBG)
    cd = ImageDraw.Draw(card)
    strip = Image.open(UI / "ui_wall_gauge_7seg_360.png")
    card.alpha_composite(strip, (30, 40))
    label(cd, (30, 16), "7 格全好（48 档，实际 HUD 用这个尺寸）", 13, C_DIM)
    strip24 = Image.open(UI / "ui_wall_gauge_7seg_180.png")
    card.alpha_composite(strip24, (30, 110))
    label(cd, (30, 88), "24 档（180×18）：切角仍在，缺口靠形状读", 13, C_DIM)
    # 真实场景：3 格损毁 + 1 格破口
    x = 400
    for i, st in enumerate(("intact", "intact", "damaged", "damaged", "breached", "intact", "intact")):
        c = Image.open(UI / f"ui_wall_cell_{st}_48.png")
        card.alpha_composite(c, (x + i * 52, 40))
    label(cd, (400, 16), "实战状态：第 3/4 段受损（裂纹）、第 5 段破口（顶部缺口 + 暗底）", 13, C_DIM)
    # 三态单独放大
    for i, st in enumerate(("intact", "damaged", "breached")):
        c = Image.open(UI / f"ui_wall_cell_{st}_48.png").resize((96, 72), Image.NEAREST)
        card.alpha_composite(c, (400 + i * 110, 120))
        label(cd, (400 + i * 110, 196), st, 12, C_DIM)
    label(cd, (750, 120), "破口格不是把颜色变暗，\n而是顶部被削出一个三角缺口\n—— 色弱玩家也能读出哪段破了", 13, C_DIM)
    sheet.alpha_composite(card, (40, y + 24))

    # ---- 5 其余小件 ----
    y = 1080
    label(d, (40, y), "5  奖励卡（灰度可染色）/ 槽位 / 提示条 / 准星 / 危险边缘 + 三角标", 15, C_ACC)
    card = Image.new("RGBA", (1420, 250), CARDBG)
    cd = ImageDraw.Draw(card)
    rcard = Image.open(UI / "ui_reward_card_frame_v1.png").resize((100, 136), Image.LANCZOS)
    # 四主题染色：**按参考灰归一**的乘法混合。
    # 直接乘会让结果永远比目标色暗一档（底色 200 灰，200/255=0.78，乘完暗 22%），
    # 实测 4 个主题全部发闷、土的黄色尤其脏。改法：先除以参考灰 REF（即边框中间调 200），
    # 得到"相对明度倍率"，再乘目标色；边框处倍率≈1，正好还原成目标色本身。
    REF = 200.0
    rp = rcard.convert("RGB").load()
    rw, rh = rcard.size
    for i, (col, nm) in enumerate((((232, 131, 74), "火"), ((102, 199, 245), "霜"),
                                   ((194, 162, 119), "土"), ((138, 59, 46), "精英"))):
        out = Image.new("RGBA", rcard.size, (0, 0, 0, 0))
        op = out.load()
        for yy in range(rh):
            for xx in range(rw):
                r0, g0, b0 = rp[xx, yy]
                k = ((r0 + g0 + b0) / 3.0) / REF
                op[xx, yy] = tuple(max(0, min(255, int(col[j] * k))) for j in range(3)) + (255,)
        out.putalpha(rcard.split()[3])
        card.alpha_composite(out, (30 + i * 108, 46))
        label(cd, (30 + i * 108 + 40, 186), nm, 12, C_DIM)
    label(cd, (30, 20), "同一张灰度卡 × 乘法染色 = 4 主题，不必出 4 张（内部暗部仍暗）", 13, C_DIM)

    slot = Image.open(UI / "ui_slot_frame_v1.png").resize((100, 100), Image.LANCZOS)
    card.alpha_composite(slot, (500, 60))
    label(cd, (500, 168), "槽位 120×120（缩显）", 12, C_DIM)

    ribbon = Image.open(UI / "ui_notice_ribbon_v1.png").resize((300, 28), Image.LANCZOS)
    card.alpha_composite(ribbon, (640, 40))
    label(cd, (640, 72), "提示条 512×48，边距 12（缩显 300×28）", 12, C_DIM)

    ch = Image.open(UI / "ui_crosshair_v1.png").resize((80, 80), Image.LANCZOS)
    card.alpha_composite(ch, (660, 120))
    label(cd, (652, 204), "准星 64² · 纸白 · 无红", 12, C_DIM)

    chev = Image.open(UI / "ui_danger_chevron_v1.png").resize((44, 44), Image.LANCZOS)
    card.alpha_composite(chev, (800, 100))
    label(cd, (778, 150), "危险三角标 48²", 12, C_DIM)

    edge = Image.open(UI / "ui_danger_edge_v1.png").resize((440, 248), Image.LANCZOS)
    card.alpha_composite(edge, (960, 0))
    label(cd, (960, 10), "危险边缘 1280×720（缩显 34%）", 12, C_DIM)
    label(cd, (960, 226), "四边 90px 内衰减，峰值 alpha 0.35", 12, C_DIM)
    sheet.alpha_composite(card, (40, y + 24))

    sheet.convert("RGB").save(UI / "_review_ui.png", quality=95)
    print(f"审阅图 → {UI / '_review_ui.png'}")

    # ---- 拉伸数值报告 ----
    print("\n=== 九宫格拉伸实测（描边宽度必须守恒） ===")
    for name, border, sizes in (
            ("ui_panel_bastion_normal_v1", 32, ((512, 512), (760, 300), (300, 900))),
            ("ui_btn_primary_normal_v1", 24, ((240, 88), (520, 88), (240, 140))),
            ("ui_reward_card_frame_v1", 20, ((220, 300), (400, 300), (220, 560))),
    ):
        src = Image.open(UI / f"{name}.png")
        for tw, th in sizes:
            out = nine_slice(src, tw, th, border)
            a = out.split()[3]
            print(f"  {name:30s} {tw:4d}×{th:<4d} alpha={a.getextrema()}")


if __name__ == "__main__":
    main()