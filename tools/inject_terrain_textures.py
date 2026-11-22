#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""inject_terrain_textures.py —— 直接改写 GLB 的 JSON chunk，给地面材质挂贴图。

依赖：只用标准库，不依赖 pygltflib。

绑定：
  Terrain_PlazaA/B/C -> tex_ground_plaza_tile_v2.png
  Terrain_Wilds      -> tex_ground_wilds_tile_v2.png
  Terrain_Scrub      -> tex_ground_scrub_tile_v2.png

贴图以外链 URI 写入 image；调用方把 PNG 放到 GLB 同目录即可。若要内嵌，
用 `--embed`，会把 PNG bytes 追加进 BIN chunk 并改成 bufferView。
"""
from __future__ import annotations

import argparse
import json
import shutil
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_GLB = ROOT / "art/assets/models/terrain/terrain_map_v001.glb"
TEX = {
    "Terrain_PlazaA": "tex_ground_plaza_tile_v2.png",
    "Terrain_PlazaB": "tex_ground_plaza_tile_v2.png",
    "Terrain_PlazaC": "tex_ground_plaza_tile_v2.png",
    "Terrain_Wilds": "tex_ground_wilds_tile_v2.png",
    "Terrain_Scrub": "tex_ground_scrub_tile_v2.png",
}


def _read_chunks(data: bytes) -> tuple[dict, bytes]:
    if len(data) < 20 or data[:4] != b"glTF":
        raise ValueError("not a GLB file")
    _magic, _version, _length = struct.unpack_from("<III", data, 0)
    json_len, json_type = struct.unpack_from("<II", data, 12)
    if json_type != 0x4E4F534A:
        raise ValueError("missing JSON chunk")
    gltf = json.loads(data[20:20 + json_len].decode("utf-8"))
    pos = 20 + json_len
    bin_chunk = b""
    if pos + 8 <= len(data):
        bin_len, bin_type = struct.unpack_from("<II", data, pos)
        if bin_type == 0x004E4942:
            bin_chunk = data[pos + 8: pos + 8 + bin_len]
    return gltf, bin_chunk


def _write_chunks(gltf: dict, bin_chunk: bytes, out: Path) -> None:
    json_bytes = json.dumps(gltf, ensure_ascii=False).encode("utf-8")
    json_pad = (4 - (len(json_bytes) % 4)) % 4
    json_bytes += b" " * json_pad
    bin_pad = (4 - (len(bin_chunk) % 4)) % 4
    bin_chunk += b"\x00" * bin_pad
    total = 12 + 8 + len(json_bytes) + 8 + len(bin_chunk)
    with out.open("wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(json_bytes), 0x4E4F534A))
        f.write(json_bytes)
        f.write(struct.pack("<II", len(bin_chunk), 0x004E4942))
        f.write(bin_chunk)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--glb", default=str(DEFAULT_GLB))
    ap.add_argument("--out", default=str(DEFAULT_GLB))
    ap.add_argument("--embed", action="store_true")
    args = ap.parse_args()

    src = Path(args.glb)
    out = Path(args.out)
    gltf, bin_chunk = _read_chunks(src.read_bytes())
    materials = gltf.get("materials", [])
    images = gltf.setdefault("images", [])
    textures = gltf.setdefault("textures", [])

    by_name = {m.get("name"): m for m in materials}
    image_by_uri = {img.get("uri"): i for i, img in enumerate(images)}
    bound = []
    for mat_name, tex_name in TEX.items():
        mat = by_name.get(mat_name)
        if mat is None:
            raise SystemExit(f"missing material: {mat_name}")
        if tex_name not in image_by_uri:
            images.append({"uri": tex_name, "mimeType": "image/png", "name": tex_name})
            image_by_uri[tex_name] = len(images) - 1
        img_idx = image_by_uri[tex_name]
        tex_idx = None
        for i, tex in enumerate(textures):
            if tex.get("source") == img_idx:
                tex_idx = i
                break
        if tex_idx is None:
            textures.append({"source": img_idx, "name": Path(tex_name).stem})
            tex_idx = len(textures) - 1
        pbr = mat.setdefault("pbrMetallicRoughness", {})
        pbr["baseColorTexture"] = {"index": tex_idx, "texCoord": 0}
        bound.append({"material": mat_name, "texture": tex_name, "image": img_idx, "texture_index": tex_idx})

    if out.exists():
        shutil.copy2(out, out.with_suffix(out.suffix + ".bak"))
    out.parent.mkdir(parents=True, exist_ok=True)
    _write_chunks(gltf, bin_chunk, out)

    print(json.dumps({"glb": str(out), "bytes": out.stat().st_size, "bound": bound,
                      "images": [{"uri": img.get("uri"), "name": img.get("name")} for img in images]},
                     ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())