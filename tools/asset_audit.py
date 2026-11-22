#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
asset_audit.py — 素材审计（只读）

用途：在"整理并导入"之前，把项目内所有 PNG 的**规格、命名、导入描述符完整性、同名冲突**
一次性查清，输出机器可读的 JSON + 人读的 Markdown 摘要。

不做任何写操作（不改文件、不移动、不删除）。发现问题只报告。

用法：
    PY tools/asset_audit.py                     # 默认扫 ./
    PY tools/asset_audit.py --root . --json art/logs/asset_audit.json

判定口径：
    runtime   位于 art/assets/**，必须能被 Godot 以 res:// 访问
    archive   位于带 .gdignore 的目录（concept/raw/review/trash/baseline），Godot 不扫描
    other     项目内其他位置（如 shots/ 调试截图）

命名规范（四段式）：<prefix>_<object>_<variant>_v<N>.<ext>
    prefix ∈ char mon env ui icon fx anim mdl tex font img
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("需要 Pillow：pip install pillow")

PREFIXES = (
    "char", "mon", "env", "ui", "icon", "fx",
    "anim", "mdl", "tex", "font", "img",
)
NAME_RE = re.compile(
    r"^(?P<prefix>[a-z]+)_(?P<object>[a-z0-9]+(?:_[a-z0-9]+)*?)_(?P<variant>[a-z0-9]+)_v(?P<ver>\d+)$"
)
SKIP_DIRS = {".godot", ".import", "__pycache__", ".workbuddy", ".git"}


def classify(path: Path, root: Path) -> str:
    rel = path.relative_to(root)
    parts = rel.parts
    if len(parts) >= 2 and parts[0] == "art" and parts[1] == "assets":
        return "runtime"
    # 向上查找是否有 .gdignore 守卫
    for parent in path.parents:
        if (parent / ".gdignore").exists():
            return "archive"
        if parent == root:
            break
    return "other"


def parse_import(imp: Path) -> dict:
    """解析 .import，取出 uid 与 remap 目标路径。

    注意：VRAM 压缩纹理的 remap 键是 `path.bptc=` / `path.s3tc=` 而不是 `path=`，
    只认 `path=` 会把正常资产误判为"缓存丢失"。这里收全部变体。
    """
    info = {"uid": None, "remap": None, "importer": None, "remap_all": []}
    if not imp.exists():
        return info
    text = imp.read_text(encoding="utf-8", errors="replace")
    m = re.search(r'^uid="(uid://[^"]+)"', text, re.M)
    if m:
        info["uid"] = m.group(1)
    for m in re.finditer(r'^path(?:\.[a-z0-9]+)?="(res://[^"]+)"', text, re.M):
        info["remap_all"].append(m.group(1))
    if info["remap_all"]:
        info["remap"] = info["remap_all"][0]
    m = re.search(r'^importer="([^"]+)"', text, re.M)
    if m:
        info["importer"] = m.group(1)
    return info


def image_facts(path: Path) -> dict:
    try:
        with Image.open(path) as im:
            w, h = im.size
            mode = im.mode
            has_alpha = mode in ("RGBA", "LA") or "transparency" in im.info
            alpha_min = None
            if has_alpha:
                a = im.convert("RGBA").getchannel("A")
                alpha_min = a.getextrema()[0]
            return {
                "w": w, "h": h, "mode": mode,
                "alpha": has_alpha, "alpha_min": alpha_min,
                "kb": round(path.stat().st_size / 1024, 1),
            }
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}


def audit(root: Path) -> dict:
    records = []
    for p in sorted(root.rglob("*.png")):
        if any(s in p.parts for s in SKIP_DIRS):
            continue
        rel = p.relative_to(root).as_posix()
        zone = classify(p, root)
        stem = p.stem
        m = NAME_RE.match(stem)
        facts = image_facts(p)
        rec = {
            "path": rel,
            "file": p.name,
            "stem": stem,
            "zone": zone,
            "dir": p.parent.relative_to(root).as_posix(),
            "naming_ok": bool(m) and m.group("prefix") in PREFIXES,
            "naming_parts": m.groupdict() if m else None,
            "res_path": ("res://" + rel) if zone == "runtime" else None,
            "facts": facts,
        }
        if zone == "runtime":
            imp = p.with_suffix(p.suffix + ".import")
            meta = parse_import(imp)
            rec["import_file"] = imp.exists()
            rec["uid"] = meta["uid"]
            rec["remap"] = meta["remap"]
            rec["remap_exists"] = any(
                (root / p.replace("res://", "")).exists() for p in meta["remap_all"]
            )
        records.append(rec)

    # 同名冲突：不同目录下同名文件
    by_name: dict[str, list[str]] = {}
    for r in records:
        by_name.setdefault(r["file"], []).append(r["path"])
    dupes = {k: v for k, v in by_name.items() if len(v) > 1}

    # 运行时体检汇总
    runtime = [r for r in records if r["zone"] == "runtime"]
    problems = []
    for r in runtime:
        if not r.get("import_file"):
            problems.append({"path": r["path"], "issue": "缺少 .import 描述符"})
            continue
        if not r.get("uid"):
            problems.append({"path": r["path"], "issue": ".import 无 uid（引擎会重新分配，引用会断）"})
        if not r.get("remap_exists"):
            problems.append({"path": r["path"], "issue": "remap 指向的 .ctex 不存在（需重新导入）"})
        if not r["naming_ok"]:
            problems.append({"path": r["path"], "issue": "命名不符合四段式"})
        f = r["facts"]
        if f.get("error"):
            problems.append({"path": r["path"], "issue": f"图片无法解码：{f['error']}"})
        elif "ui" in r["path"] or "icon" in r["path"]:
            if f["mode"] != "RGBA":
                problems.append({"path": r["path"], "issue": f"UI/图标非 RGBA（{f['mode']}），无透明通道"})
        # NPOT 只对需要平铺/压缩/mipmap 的场景贴图是真问题；
        # UI 与图标的非 2 幂尺寸（240×88、380×16、24×18…）是设计值，不报。
        f_w = r["facts"].get("w") or 0
        needs_pot = ("/env/" in r["path"]) or r["stem"].startswith("tex_") or r["stem"].startswith("env_")
        if not r["facts"].get("error") and needs_pot and f_w and (f_w & (f_w - 1)) != 0:
            problems.append({"path": r["path"], "issue": f"宽度 {f_w} 非 2 的幂（平铺贴图需 POT 才稳，mipmap/压缩会偏）"})

    summary = {
        "root": str(root),
        "total_png": len(records),
        "runtime": len(runtime),
        "archive": sum(1 for r in records if r["zone"] == "archive"),
        "other": sum(1 for r in records if r["zone"] == "other"),
        "runtime_ok": sum(1 for r in runtime if r.get("import_file") and r.get("uid") and r.get("remap_exists") and r["naming_ok"]),
        "runtime_problems": problems,
        "duplicate_names": dupes,
    }
    return {"summary": summary, "records": records}


def to_markdown(data: dict) -> str:
    s = data["summary"]
    lines = [
        "# 素材审计结果（只读扫描）",
        "",
        f"- 扫描 PNG 总数：**{s['total_png']}**",
        f"- 运行时区（art/assets）：**{s['runtime']}**，其中四项体检全过：**{s['runtime_ok']}**",
        f"- 归档区（.gdignore 守卫）：**{s['archive']}**　｜　其他：**{s['other']}**",
        "",
    ]
    if s["runtime_problems"]:
        lines += ["## 运行时区问题", "", "| 路径 | 问题 |", "|---|---|"]
        lines += [f"| `{p['path']}` | {p['issue']} |" for p in s["runtime_problems"]]
        lines.append("")
    else:
        lines += ["## 运行时区问题", "", "无。", ""]
    if s["duplicate_names"]:
        lines += ["## 同名文件（跨目录）", "", "| 文件名 | 出现位置 |", "|---|---|"]
        for name, paths in sorted(s["duplicate_names"].items()):
            lines.append(f"| {name} | " + "<br>".join(f"`{p}`" for p in paths) + " |")
        lines.append("")
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".", help="项目根目录")
    ap.add_argument("--json", default="art/logs/asset_audit.json", help="JSON 输出路径")
    ap.add_argument("--md", default="art/logs/asset_audit.md", help="Markdown 输出路径")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    data = audit(root)
    out_json = root / args.json
    out_md = root / args.md
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    out_md.write_text(to_markdown(data), encoding="utf-8")

    s = data["summary"]
    print(f"total={s['total_png']} runtime={s['runtime']} ok={s['runtime_ok']} "
          f"archive={s['archive']} other={s['other']} "
          f"problems={len(s['runtime_problems'])} dupes={len(s['duplicate_names'])}")
    for p in s["runtime_problems"]:
        print(f"  ! {p['path']} :: {p['issue']}")
    print(f"-> {out_json.relative_to(root).as_posix()}")
    print(f"-> {out_md.relative_to(root).as_posix()}")


if __name__ == "__main__":
    main()
