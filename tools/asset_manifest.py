#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
asset_manifest.py — 运行时素材清单生成（只读素材，产出清单文件）

输入：art/logs/asset_audit.json（由 asset_audit.py 生成）
输出：
    art/logs/asset_manifest.tsv   机器可读：res:// 路径 / uid / 尺寸 / 格式 / 用途 / 优先级
    art/logs/asset_manifest.md    人读表格（直接进导入文档的"已导入"章节）

用途与优先级来自下方 ROLE 表（与 `城墙尸潮-美术资产清单.md` 对齐）。
新增素材时在 ROLE 里补一行即可，无需改代码。

用法：
    PY tools/asset_audit.py && PY tools/asset_manifest.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# stem -> (用途, 优先级, 备注)
ROLE: dict[str, tuple[str, str, str]] = {
    "env_crack_decal_v1": ("墙段受损裂纹贴花（3 档靠透明度复用）", "P0", "透明贴花，mipmap 开"),
    "env_far_tree_v1": ("远景枯树剪影牌", "P1", "透明剪影，4 件中的 1 件"),
    "env_sky_dusk_v1": ("暮色天空底图（5 波靠染色复用）", "P1", "1536×1024，未达清单 2048 规格"),
    "tex_ground_plaza_tile_v1": ("城内地面可平铺贴图", "P0", "POT，可平铺，需 4 向随机铺贴"),
    "tex_ground_wilds_tile_v1": ("城外搜集区地面可平铺贴图", "P0", "POT，可平铺，建议叠枯草 decal"),
    "icon_coin_small_v1": ("货币图标（HUD 资源区）", "P0", "96²，显示 24–48px"),
    "icon_brick_small_v1": ("砖块图标（修墙决策）", "P0", "96²"),
    "icon_metal_small_v1": ("金属图标", "P1", "96²"),
    "icon_ammo_small_v1": ("弹药图标", "P1", "96²"),
    "icon_weapon_crossbow_v1": ("武器槽 1/2 — 弩", "P1", "最小使用 48px"),
    "icon_tool_hammer_v1": ("武器槽 3 — 锤", "P1", "最小使用 48px"),
    "icon_tool_knife_v1": ("武器槽 4 — 刀", "P1", "最小使用 48px"),
    "ui_panel_bastion_normal_v1": ("商店/奖励面板底", "P0", "九宫格边距 32 未落代码"),
    "ui_btn_primary_normal_v1": ("主按钮 — 常态", "P0", "九宫格边距 24 未落代码"),
    "ui_btn_primary_pressed_v1": ("主按钮 — 按下", "P0", "同上"),
    "ui_btn_primary_disabled_v1": ("主按钮 — 禁用", "P0", "同上"),
    "ui_wall_gauge_7seg360_v1": ("城墙 7 格刻度 — 大档", "P0", "实际 360×36，清单文字为 48×36，已过期"),
    "ui_wall_gauge_7seg180_v1": ("城墙 7 格刻度 — 小档", "P0", "实际 180×18"),
    "ui_wall_cell_intact48_v1": ("墙格 — 完好 大档", "P0", ""),
    "ui_wall_cell_damaged48_v1": ("墙格 — 受损 大档", "P0", ""),
    "ui_wall_cell_breached48_v1": ("墙格 — 破口 大档", "P0", ""),
    "ui_wall_cell_intact24_v1": ("墙格 — 完好 小档", "P0", ""),
    "ui_wall_cell_damaged24_v1": ("墙格 — 受损 小档", "P0", ""),
    "ui_wall_cell_breached24_v1": ("墙格 — 破口 小档", "P0", ""),
    "ui_bar_frame_v1": ("血条外框中空", "P0", "九宫格横向 8px 填充"),
    "ui_bar_fill_v1": ("血条填充（纯白染色）", "P0", "<16px 需改圆头矩形，见清单 §6.1"),
    "ui_bar_bg_v1": ("血条底", "P0", ""),
    "ui_reward_card_frame_v1": ("波末三选一奖励卡框", "P1", "染色前按参考灰 200 归一"),
    "ui_slot_frame_v1": ("武器槽框", "P1", ""),
    "ui_crosshair_normal_v1": ("准星", "P1", "2026-11-06 由 ui_crosshair_v1 补变体段重命名"),
    "ui_notice_ribbon_v1": ("顶部提示条", "P2", "九宫格边距 12 未落代码"),
    "ui_danger_edge_v1": ("破口方向四边脉动条", "P1", "峰值 alpha 0.35"),
    "ui_danger_chevron_v1": ("破口方向三角标", "P1", ""),
}


def main() -> None:
    audit_path = ROOT / "art/logs/asset_audit.json"
    if not audit_path.exists():
        sys.exit("先运行 tools/asset_audit.py 生成 asset_audit.json")
    data = json.loads(audit_path.read_text(encoding="utf-8"))

    rows = []
    for r in data["records"]:
        if r["zone"] != "runtime":
            continue
        stem = r["stem"]
        use, prio, note = ROLE.get(stem, ("（用途未登记）", "—", ""))
        f = r["facts"]
        rows.append({
            "res": r["res_path"],
            "uid": r.get("uid") or "",
            "w": f.get("w", 0),
            "h": f.get("h", 0),
            "mode": f.get("mode", ""),
            "kb": f.get("kb", 0),
            "use": use,
            "prio": prio,
            "note": note,
        })
    rows.sort(key=lambda x: (x["prio"], x["res"]))

    tsv = ["res_path\tuid\twidth\theight\tformat\tkb\tuse\tpriority\tnote"]
    for x in rows:
        tsv.append(f'{x["res"]}\t{x["uid"]}\t{x["w"]}\t{x["h"]}\t{x["mode"]}\t{x["kb"]}\t{x["use"]}\t{x["prio"]}\t{x["note"]}')
    (ROOT / "art/logs/asset_manifest.tsv").write_text("\n".join(tsv) + "\n", encoding="utf-8")

    md = [
        f"已登记运行时素材 **{len(rows)}** 件（P0 {sum(1 for x in rows if x['prio']=='P0')} ／ "
        f"P1 {sum(1 for x in rows if x['prio']=='P1')} ／ P2 {sum(1 for x in rows if x['prio']=='P2')}）。",
        "",
        "| # | res:// 路径 | 尺寸 | 格式 | uid | 用途 | 优先级 | 备注 |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for i, x in enumerate(rows, 1):
        md.append(
            f'| {i} | `{x["res"]}` | {x["w"]}×{x["h"]} | {x["mode"]} | `{x["uid"]}` | '
            f'{x["use"]} | {x["prio"]} | {x["note"]} |'
        )
    (ROOT / "art/logs/asset_manifest.md").write_text("\n".join(md) + "\n", encoding="utf-8")

    unreg = [x["res"] for x in rows if x["use"] == "（用途未登记）"]
    print(f"manifest rows={len(rows)} unregistered={len(unreg)}")
    for u in unreg:
        print("  ? 未登记用途:", u)
    print("-> art/logs/asset_manifest.tsv")
    print("-> art/logs/asset_manifest.md")


if __name__ == "__main__":
    main()
