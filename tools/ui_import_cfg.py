#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ui_import_cfg.py —— 为运行时纹理写 Godot .import 参数

为什么需要这个脚本：Godot 默认把所有 png 当成"普通纹理"导入，默认参数对 UI 是错的。
实测三类强制需求：

  1. UI 九宫格必须开 `process/fix_alpha_border` **但关 mipmap** ——
     开了 mipmap 后，九宫格的 1px 描边在缩小时会被平均掉，边框糊成一片。
  2. 可平铺地面贴图必须开 `repeat`（detect_3d/compress_to 会把 wrap 设成 clamp）
     + 开 mipmap，否则远处地面会闪烁（摩尔纹）。
  3. 图标必须 `compress/mode=0`（无损），因为 96² 再压缩会出现色块。

`.import` 文件由 Godot 生成；本脚本只**改参数行**，不动 uid 与路径。
必须在 Godot 首次导入之后跑（否则没有 uid）。
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UI_DIR = ROOT / "art/assets/ui"
ICON_DIR = ROOT / "art/assets/icon"
ENV_DIR = ROOT / "art/assets/env"

# 参数组：(匹配规则, 参数字典, 理由)
PROFILES: list[tuple[str, dict[str, str], str]] = [
    # ---- UI：无 mipmap、无损、九宫格友好 ----
    (r"ui_.*\.png$", {
        "compress/mode": "0",
        "mipmaps/generate": "false",
        "process/fix_alpha_border": "false",
        "detect_3d/compress_to": "0",
    }, "UI 图：关 mipmap（否则 1px 描边被平均掉）、关 alpha 边修复（会改写圆角抗锯齿）"),

    # ---- 图标：无 mipmap、无损 ----
    (r"icon_.*\.png$", {
        "compress/mode": "0",
        "mipmaps/generate": "false",
        "process/fix_alpha_border": "false",
        "detect_3d/compress_to": "0",
    }, "图标：96² 无损，关 mipmap 保锐利边缘"),

    # ---- 地面贴图：重复 + mipmap ----
    (r"tex_ground_.*\.png$", {
        "compress/mode": "2",
        "compress/high_quality": "true",
        "mipmaps/generate": "true",
        "detect_3d/compress_to": "0",
        "process/fix_alpha_border": "true",
    }, "可平铺地面：开 mipmap 防远处摩尔纹；VRAM 压缩省显存"),

    # ---- 天空底图：单张全屏，不重复 ----
    (r"env_sky_.*\.png$", {
        "compress/mode": "2",
        "compress/high_quality": "true",
        "mipmaps/generate": "false",
        "detect_3d/compress_to": "0",
    }, "天空：单张铺满，不需 mipmap，用 VRAM 压缩"),

    # ---- 剪影 / 贴花：alpha 关键 ----
    (r"(env_far_tree|env_crack_decal).*\.png$", {
        "compress/mode": "0",
        "mipmaps/generate": "true",
        "process/fix_alpha_border": "true",
        "detect_3d/compress_to": "0",
    }, "剪影贴花：插值缩放需要 mipmap；alpha 边修复防黑边"),
]


def apply(imp: Path, params: dict[str, str]) -> list[str]:
    """只改存在的参数行，返回改动说明。不新增行——新增参数应由 Godot 版本决定。"""
    text = imp.read_text(encoding="utf-8")
    changes: list[str] = []
    for k, v in params.items():
        pat = re.compile(rf"^{re.escape(k)}=(.*)$", re.M)
        m = pat.search(text)
        if not m:
            changes.append(f"    (缺 {k}，跳过——该 Godot 版本无此参数)")
            continue
        if m.group(1) == v:
            continue
        text = pat.sub(f"{k}={v}", text, count=1)
        changes.append(f"    {k}: {m.group(1)} → {v}")
    if changes:
        imp.write_text(text, encoding="utf-8")
    return changes


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    total = 0
    for imp in sorted(ROOT.rglob("*.png.import")):
        rel = str(imp.relative_to(ROOT)).replace("\\", "/")
        if "/art/assets/" not in "/" + rel:
            continue
        if "/art/trash/" in "/" + rel:
            continue
        name = imp.name[:-7]  # 去掉 .import
        for pat, params, why in PROFILES:
            if re.search(pat, name):
                ch = apply(imp, params) if not args.dry_run else ["    (dry-run)"]
                if ch:
                    total += 1
                    print(f"{rel}\n  {why}")
                    for c in ch:
                        print(c)
                break
    print(f"\n{'预演' if args.dry_run else '已更新'} {total} 个 .import")


if __name__ == "__main__":
    main()