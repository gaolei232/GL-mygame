# -*- coding: utf-8 -*-
"""
给地形加"游戏上下文占位体"并渲染验收图。

为什么需要：地形资产本身只有地面 + 石头 + 树，而玩家实际看到的是
"地面 + 城墙 + 水晶 + 火盆"的合成画面。只渲染地形无法判断构图是否成立。

这里的城墙 / 水晶**完全按游戏代码的参数生成**，用来对齐观感：
  core/game_state.gd::_build_wall
      center = Vector2(sin(a), -cos(a)) * wall_radius
      a = ((i+0.5)/count - 0.5) * arc,  arc = 150°, count = 7
  data/balance.json
      wall_radius 18, wall_height 3.5, wall_thickness 1.2, crystal_radius 4
  world_builder.gd
      墙 BoxMesh(length, 3.5, 1.2)；水晶 CylinderMesh(top 1.0, bottom 1.6, h 4.2)

脚本做的事情：
  1) 打开地形 .blend
  2) 建 QA_Context 集合（7 段墙 + 水晶 + 7 个火盆）
  3) 渲染三张票：城内实际视角 / 中景 / 全图
  4) **不保存** —— 上下文不会污染交付资产
"""

import bpy, math, sys
from math import sin, cos, radians, pi
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
def arg(name, default=None):
    if name in argv:
        return argv[argv.index(name) + 1]
    return default

BLEND = bpy.data.filepath
RENDER_DIR = arg("--outdir", None)

WALL_RADIUS = 18.0
WALL_ARC = radians(150.0)
WALL_COUNT = 7
WALL_H = 3.5
WALL_T = 1.2

def srgb(hexstr):
    h = hexstr.lstrip('#')
    out = []
    for i in (0, 2, 4):
        c = int(h[i:i + 2], 16) / 255.0
        out.append(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4)
    return tuple(out)

def make_mat(name, hexc, rough=0.88, emit=None, emit_energy=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes.get("Principled BSDF")
    b.inputs["Base Color"].default_value = (*srgb(hexc), 1.0)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = 0.0
    if emit is not None:
        b.inputs["Emission Color"].default_value = (*srgb(emit), 1.0)
        b.inputs["Emission Strength"].default_value = emit_energy
    return m

mat_wall = make_mat("QA_Wall_Earth", "#C2A277", 0.88)
mat_wall_dark = make_mat("QA_Wall_Base", "#8A6F52", 0.90)
mat_crystal = make_mat("QA_Crystal", "#66C7F5", 0.30, emit="#66C7F5", emit_energy=2.2)
mat_ember = make_mat("QA_Ember", "#E8834A", 0.60, emit="#E8834A", emit_energy=3.0)

coll = bpy.data.collections.new("QA_Context")
bpy.context.scene.collection.children.link(coll)

def add_box(name, size, loc, rot_z, mat):
    me = bpy.data.meshes.new(name + "_m")
    # 用 bmesh 建长方体
    import bmesh
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bm.to_mesh(me); bm.free()
    ob = bpy.data.objects.new(name, me)
    ob.scale = Vector(size)
    ob.location = Vector(loc)
    ob.rotation_euler = (0.0, 0.0, rot_z)
    ob.data.materials.append(mat)
    coll.objects.link(ob)
    return ob

# ---- 7 段城墙（按 game_state._build_wall 的公式） ----
for i in range(WALL_COUNT):
    t = (float(i) + 0.5) / float(WALL_COUNT) - 0.5
    a = t * WALL_ARC
    # 游戏坐标 (x, z) = (sin a, -cos a) * R  ->  Blender (gx, gy) = (x, -z)
    gx = sin(a) * WALL_RADIUS
    gy = cos(a) * WALL_RADIUS
    half_len = (WALL_ARC * WALL_RADIUS / float(WALL_COUNT)) * 0.5 + 0.1
    length = half_len * 2.0
    # 游戏系 tangent = (cos a, sin a)（游戏 x,z 平面）
    # 映射到 Blender 地面：gx = x, gy = -z  =>  tangent = (cos a, -sin a)
    # 墙本地 +X 对齐该切线 => rot_z = atan2(-sin a, cos a) = -a
    rot_z = -a
    z = WALL_H * 0.5
    add_box(f"QA_Wall_{i}", (length, WALL_T, WALL_H), (gx, gy, z), rot_z, mat_wall)
    # 墙基（略宽略暗，压住墙脚）
    add_box(f"QA_WallBase_{i}", (length * 1.02, WALL_T * 1.5, 0.45),
            (gx, gy, 0.22), rot_z, mat_wall_dark)

# ---- 水晶 ----
bpy.ops.mesh.primitive_cone_add(vertices=8, radius1=1.6, radius2=1.0, depth=4.2,
                                location=(0, 0, 2.1))
crystal = bpy.context.active_object
crystal.name = "QA_Crystal"
crystal.data.materials.append(mat_crystal)
for c in list(crystal.users_collection):
    c.objects.unlink(crystal)
coll.objects.link(crystal)

# ---- 火盆（7 段墙各一个，暖光锚点） ----
for i in range(WALL_COUNT):
    t = (float(i) + 0.5) / float(WALL_COUNT) - 0.5
    a = t * WALL_ARC
    px = sin(a) * (WALL_RADIUS - 1.3)
    py = cos(a) * (WALL_RADIUS - 1.3)
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=0.34,
                                         location=(px, py, 0.55))
    ob = bpy.context.active_object
    ob.name = f"QA_Ember_{i}"
    ob.data.materials.append(mat_ember)
    for c in list(ob.users_collection):
        c.objects.unlink(ob)
    coll.objects.link(ob)
    light_data = bpy.data.lights.new(f"QA_EmberLight_{i}", type='POINT')
    light_data.color = srgb("#E8834A")
    light_data.energy = 120.0
    light_data.shadow_soft_size = 0.4
    lo = bpy.data.objects.new(f"QA_EmberLight_{i}", light_data)
    lo.location = (px, py, 1.1)
    coll.objects.link(lo)

print(f"QA context built: walls={WALL_COUNT} + crystal + embers, "
      f"objects={len(coll.objects)}")

# ---- 渲染 ----
scene = bpy.context.scene
if RENDER_DIR:
    import os
    os.makedirs(RENDER_DIR, exist_ok=True)

CAMS = {
    "city": ("Cam_Game_City", 1280, 720),
    "wide": ("Cam_Game_Wide", 1280, 720),
    "iso": ("Cam_Iso_Overview", 1600, 900),
}
for tag, (cam_name, w, h) in CAMS.items():
    cam = bpy.data.objects.get(cam_name)
    if cam is None:
        continue
    scene.camera = cam
    scene.render.resolution_x = w
    scene.render.resolution_y = h
    scene.eevee.taa_render_samples = 48
    scene.render.filepath = f"{RENDER_DIR}/v015_{tag}_with_context.png"
    bpy.ops.render.render(write_still=True)
    print("RENDERED", scene.render.filepath)