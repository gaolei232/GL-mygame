#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""import_assets.py —— 素材分流与规范化导入

三条硬约束（本脚本的全部设计动机）：
  1. **不覆盖**：目标已存在就跳过并记入日志，绝不 shutil.move 覆盖。
  2. **可追溯**：每一步写 art/logs/import_YYYY-MM-DD.md，含源路径、目标路径、依据。
  3. **按用途分流**：项目是 3D 低模路线，角色/怪物/城墙/水晶/火盆的 2D 图是
     **建模参考**，不是运行时纹理。混在 art/assets 里会被 Godot 当纹理导入，
     白占显存且污染资源树。因此参考图统一进 art/concept/，并加 .gdignore。

用法：
  python tools/import_assets.py --dry-run    # 只打印计划
  python tools/import_assets.py             # 执行
"""

from __future__ import annotations

import argparse
import shutil
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "art/assets"
BASELINE = ROOT / "art/baseline"
CONCEPT = ROOT / "art/concept"
REVIEW = ROOT / "art/review"
TRASH = ROOT / "art/trash"
LOGS = ROOT / "art/logs"

# ---------------------------------------------------------------- 迁移计划
# (源, 目标, 依据)  目标为 None 表示只删 .import 孤儿，不移动文件
ICONS = ["coin", "brick", "metal", "ammo"]
WEAPONS = ["tool_hammer", "tool_knife", "weapon_crossbow"]
CELL_STATES = ["intact", "damaged", "breached"]


def build_plan() -> list[tuple[Path, Path | None, str]]:
    p: list[tuple[Path, Path | None, str]] = []

    # ---- 1. 图标：96² 是清单规定的运行时尺寸，改名补 _v1 ----
    for n in ICONS:
        p.append((ASSETS / "icon" / f"icon_{n}_small_96.png",
                  ASSETS / "icon" / f"icon_{n}_small_v1.png",
                  "清单 §2.4：运行时规格 96²，补 v1 版本段"))
    for n in WEAPONS:
        p.append((ASSETS / "icon" / f"icon_{n}_96.png",
                  ASSETS / "icon" / f"icon_{n}_v1.png",
                  "清单 §2.4：运行时规格 96²，补 v1 版本段"))

    # ---- 2. 图标母版 192/512：不进运行时，96² 已够 HUD 与列表 ----
    for n in ICONS:
        for s in (192, 512):
            p.append((ASSETS / "icon" / f"icon_{n}_small_{s}.png",
                      CONCEPT / "master" / f"icon_{n}_small{s}_v1.png",
                      f"母版 {s}²：运行时只用 96²，母版留档供超过 96px 显示时替换"))
    for n in WEAPONS:
        for s in (192, 512):
            p.append((ASSETS / "icon" / f"icon_{n}_{s}.png",
                      CONCEPT / "master" / f"icon_{n}{s}_v1.png",
                      f"母版 {s}²：运行时只用 96²，母版留档供超过 96px 显示时替换"))

    # ---- 3. UI：尺寸段挪到版本号之前 ----
    for s in CELL_STATES:
        for sz in (48, 24):
            p.append((ASSETS / "ui" / f"ui_wall_cell_{s}_{sz}.png",
                      ASSETS / "ui" / f"ui_wall_cell_{s}{sz}_v1.png",
                      "四段式：尺寸属变体段，必须排在 _vN 之前"))
    for sz in (360, 180):
        p.append((ASSETS / "ui" / f"ui_wall_gauge_7seg_{sz}.png",
                  ASSETS / "ui" / f"ui_wall_gauge_7seg{sz}_v1.png",
                  "四段式：尺寸属变体段，必须排在 _vN 之前"))

    # ---- 4. 场景：待建模的基准图移出运行时 ----
    for n, why in (
            ("env_wall_rampart_normal_v2.png", "清单 #16：城墙为 3D 低模，此图是建模基准图（待建模）"),
            ("env_crystal_core_v1.png", "清单 #17：水晶为 3D 低模，此图是建模基准图（待建模）"),
            ("env_brazier_normal_v1.png", "清单 #22：火盆为 3D 低模，此图是建模基准图（待建模）"),
    ):
        stem = n[:-4]
        # concept 区统一加 concept_ 前缀，避免与运行时同名文件混淆
        p.append((ASSETS / "env" / n, CONCEPT / "env" / f"concept_{stem}.png", why))

    # ---- 5. 怪物：五只全部为建模基准图 ----
    for n in ("mon_walker_normal_v1", "mon_runner_normal_v1", "mon_bomber_normal_v2",
              "mon_brute_normal_v2", "mon_boss_normal_v2"):
        p.append((ASSETS / "mon" / f"{n}.png", CONCEPT / "mon" / f"concept_{n}.png",
                  "清单 §2.2：五只均为 3D 低模基准图（待建模），非运行时纹理"))

    # ---- 6. 箱子：清单明确"带投影，仅建模参考" ----
    for n in ("wood", "metal", "military"):
        p.append((ASSETS / "prop" / f"mdl_loot_box_{n}_512.png",
                  CONCEPT / "prop" / f"concept_loot_box_{n}_v1.png",
                  "清单 §2.4 / §18.6：投影抠不净，明确仅作建模参考"))
        for s in (192, 96):
            p.append((ASSETS / "prop" / f"mdl_loot_box_{n}_{s}.png", None,
                      f"派生态 {s}²：母版转参考后不再需要，删除（母版保留）"))

    # ---- 7. 审阅拼版：不属于任何资产，进 review 区 ----
    for src, dst, why in (
            ("icon/_review_icons.png", "review_icons_v1.png", "第 4 批图标验收拼版"),
            ("icon/_review_24px.png", "review_icons24px_v1.png", "第 4 批 24px 可辨性验收"),
            ("prop/_review_crates.png", "review_crates_v1.png", "第 4 批箱子验收拼版"),
            ("mon/_contact_sheet.png", "review_mon_contact_v1.png", "第 2 批感染者族梯度接触表"),
            ("ui/_review_ui.png", "review_ui_v1.png", "第 5 批 UI 验收拼版"),
    ):
        p.append((ASSETS / src, REVIEW / dst, why))

    # ---- 8. baseline 里已抠好的成品：与 assets 重复，归档不删 ----
    for n in ("char_hero_normal_v4_raw_flood.png",):
        p.append((BASELINE / n, CONCEPT / "char" / "concept_char_hero_normal_v4.png",
                  "第 1 批玩家最终基准（已抠底），移入概念区"))
    p.append((BASELINE / "mon_walker_normal_v1_flood.png", None,
              "与 concept_mon_walker_normal_v1 重复的中间抠图，删除（成品已归档）"))
    p.append((BASELINE / "_test_v4_alpha.png", None,
              "抠图工具调试残留（四角 alpha 不一致），删除"))

    # ---- 9. 原始出图与 AI 材质图：归入 raw，不参与导入 ----
    for f in sorted(BASELINE.glob("*_raw.png")):
        p.append((f, ROOT / "art/raw/steps" / f.name, "生成原始图（未处理），归入 raw/steps"))
    for n in ("env_brazier_normal_v1.png", "env_crack_decal_v1.png", "env_crystal_core_v1.png",
              "env_far_tree_v1.png", "env_sky_dusk_v1.png", "env_wall_rampart_normal_v2.png",
              "tex_ground_plaza_tile_v1.png", "tex_ground_wilds_tile_v1.png",
              "tex_ground_wilds_tile_v2.png", "sheet_icons_resource_v1.png",
              "sheet_icons_weapon_v1.png", "sheet_loot_crates_v1.png",
              "icon_tool_knife_raw_v2.png", "env_wall_rampart_normal_v1_raw.png"):
        p.append((BASELINE / n, ROOT / "art/raw/baseline" / n,
                  "baseline 副本：与 assets 内成品并存，统一归入 raw/baseline 留档"))

    return p


# ---------------------------------------------------------------- 执行

def ensure_gdignore(dry: bool, log: list[str]) -> None:
    """给非运行时目录加 .gdignore，让 Godot 完全不扫描。

    为什么必要：Godot 会导入项目内**所有** png。实测 baseline/ 下 29 张
    1024² 概念图已被导入并生成 .ctex，白占显存、拖慢编辑器、还会出现在
    资源搜索里。.gdignore 是唯一干净的隔离手段。
    """
    for d in (CONCEPT, REVIEW, ROOT / "art/raw", TRASH, BASELINE, LOGS):
        f = d / ".gdignore"
        if f.exists():
            continue
        log.append(f"新建 {f.relative_to(ROOT)}")
        if not dry:
            d.mkdir(parents=True, exist_ok=True)
            f.write_text("", encoding="utf-8")


def purge_orphan_imports(dry: bool, log: list[str]) -> int:
    """把对应 png 已不存在的 .import 归档到 trash。

    Godot 靠 .import 记录 uid 与导入参数。png 改名/移走后旧 .import 成为孤儿，
    编辑器会给每个孤儿报 "missing source" 警告，且会让 uid 缓存变脏。
    不用 unlink：Windows 沙箱下 safe-delete 会拦，且删掉不可追溯。
    """
    n = 0
    for imp in sorted(ROOT.rglob("*.png.import")):
        if TRASH in imp.parents:
            continue
        src = Path(str(imp)[:-7])
        if src.exists():
            continue
        n += 1
        tgt = _trash_path(imp)
        log.append(f"归档孤儿 `{tgt.relative_to(ROOT)}` ← {imp.relative_to(ROOT)}（源 {src.name} 已不在原位）")
        if not dry:
            TRASH.mkdir(parents=True, exist_ok=True)
            shutil.move(str(imp), str(tgt))
    return n


def _trash_path(src: Path) -> Path:
    """trash 目标路径：保留原父目录名做前缀，避免不同目录同名文件互相覆盖。

    踩过的坑：一开始直接用 `TRASH / src.name`，baseline/ 与 assets/env/ 下都有
    `env_brazier_normal_v1.png.import`，第二次 move 时目标已存在 → shutil.move 在
    Windows 上回退到 copy+unlink，unlink 被沙箱 safe-delete 拦住，整个脚本中断。
    """
    parent = src.parent.name
    cand = TRASH / f"{parent}__{src.name}"
    if not cand.exists():
        return cand
    i = 2
    while True:
        c = TRASH / f"{parent}__{src.stem}__{i}{src.suffix}"
        if not c.exists():
            return c
        i += 1


def move(src: Path, dst: Path | None, why: str, dry: bool, log: list[str]) -> str:
    """返回 ok / skip-missing / skip-exists / deleted。

    `dst is None` 表示"不进运行时"，一律**移入 art/trash/ 而不是 unlink**：
      · 可追溯：任何"删掉"的动作都能在 trash 里找回
      · 绕过 Windows 沙箱回收站不可用的限制（实测 unlink 会被 safe-delete 拦下）
    """
    if not src.exists():
        log.append(f"**跳过** {src.relative_to(ROOT)} — 源不存在（可能已迁移）")
        return "skip-missing"
    if dst is None:
        tgt = _trash_path(src)
        log.append(f"归档到 `{tgt.relative_to(ROOT)}` ← {src.relative_to(ROOT)} — {why}")
        if not dry:
            TRASH.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), str(tgt))
        return "deleted"
    if dst.exists():
        log.append(f"**冲突** {dst.relative_to(ROOT)} 已存在，不覆盖；源 {src.relative_to(ROOT)} 保留原地")
        return "skip-exists"
    log.append(f"`{src.relative_to(ROOT)}` → `{dst.relative_to(ROOT)}` — {why}")
    if not dry:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dst))
    return "ok"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    dry = args.dry_run
    log: list[str] = []

    plan = build_plan()
    stats = {"ok": 0, "deleted": 0, "skip-missing": 0, "skip-exists": 0}
    for src, dst, why in plan:
        r = move(src, dst, why, dry, log)
        stats[r] = stats.get(r, 0) + 1

    ensure_gdignore(dry, log)
    n_orphan = purge_orphan_imports(dry, log)

    # 空目录保留不删：Windows 沙箱下 rmdir 会被 safe-delete 拦，且空目录无害。
    # 只要目录里没有 png，Godot 就不会导入任何东西。
    for d in (ASSETS / "mon", ASSETS / "prop"):
        if d.exists() and not any(d.iterdir()):
            log.append(f"（空目录保留）{d.relative_to(ROOT)}")

    title = "预演（未落盘）" if dry else "已执行"
    header = [
        f"# 素材导入日志 · {date.today().isoformat()}",
        "",
        f"> 状态：**{title}** ｜ 工具：`tools/import_assets.py`",
        f"> 统计：移动 {stats['ok']} ／ 删除 {stats['deleted']} ／ "
        f"源缺失 {stats['skip-missing']} ／ 命名冲突 {stats['skip-exists']} ／ 清孤儿 .import {n_orphan}",
        "",
        "## 逐步记录",
        "",
    ]
    out = LOGS / f"import_{date.today().isoformat()}.md"
    if not dry:
        LOGS.mkdir(parents=True, exist_ok=True)
        out.write_text("\n".join(header + [f"- {x}" for x in log]) + "\n", encoding="utf-8")

    print(f"{title}：移动 {stats['ok']}，删除 {stats['deleted']}，"
          f"源缺失 {stats['skip-missing']}，冲突 {stats['skip-exists']}，孤儿 {n_orphan}")
    if dry:
        for x in log:
            print("  ", x)
    else:
        print("日志 →", out.relative_to(ROOT))


if __name__ == "__main__":
    main()