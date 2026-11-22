# -*- coding: utf-8 -*-
"""
在 Blender 图形界面里"看"地形一层层长出来
==========================================

用法（关键：**不要**加 --background，否则你看不到视口）：

  1) 打开 Blender（双击 blender.exe）
  2) 顶部切到 Scripting 工作区
  3) Open -> 选中本文件 -> 点 ▶ Run Script
  4) 切回 Layout 视口，按 小键盘 7（顶视）/ 5（正交）看地形分阶段长出

它做什么：用 bpy.app.timers 每 0.35 秒推进一步，共 5 步，
你能在视口里看到"平地 -> 丘陵 -> 山脊 -> 着色 -> 道具"的过程。
每步进度会打印在 Blender 的 System Console / Info 栏。

这个文件是**教学演示用的简化版**；正式生成器是 generate_terrain_v2.py。

注意：运行会清空当前场景（未保存的内容会丢，先 Ctrl+S）。
"""

import bpy, bmesh, math, random
from math import hypot, exp, sin, cos, radians, pi
from mathutils import Vector, Matrix

SIZE = 320.0
CELL = 2.5                 # 演示用粗网格，跑得快、看得清
N = int(SIZE / CELL)
HALF = SIZE / 2.0
SEED = 20261115

# ---------------------------------------------------------------- 噪声
def _h(ix, iy, s):
    n = (ix * 374761393 + iy * 668265263 + s * 1442695041) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return (n ^ (n >> 16)) & 0x7FFFFFFF

def r01(ix, iy, s):
    return _h(ix, iy, s) / 2147483647.0

def vn(x, y, s):
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy
    u = fx * fx * (3 - 2 * fx); v = fy * fy * (3 - 2 * fy)
    a = r01(ix, iy, s); b = r01(ix + 1, iy, s)
    c = r01(ix, iy + 1, s); d = r01(ix + 1, iy + 1, s)
    return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v

def fbm(x, y, oct, s):
    t = 0.0; amp = 0.5; f = 1.0; nrm = 0.0
    for i in range(oct):
        t += amp * vn(x * f, y * f, s + i * 17)
        nrm += amp; amp *= 0.5; f *= 2
    return t / nrm

def ridge(x, y, oct, s):
    t = 0.0; amp = 0.5; f = 1.0; nrm = 0.0
    for i in range(oct):
        n = vn(x * f, y * f, s + i * 31)
        r = 1.0 - abs(2 * n - 1)
        t += amp * r * r
        nrm += amp; amp *= 0.5; f *= 2
    return t / nrm

def ss(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)

# ---------------------------------------------------------------- 地形公式
def flat_radius(gx, gy):
    n = fbm(gx * 0.013, gy * 0.013, 3, 501)
    base = 52.0 + 9.0 * (n - 0.5) * 2
    r = hypot(gx, gy)
    if r < 1e-6:
        return base
    d = gy / r
    return base + 34.0 * max(0.0, d) ** 2

def mountain_mask(gx, gy):
    n = fbm(gx * 0.0042, gy * 0.0042, 3, 901)
    m = ss((n - 0.385) / 0.20)
    r = hypot(gx, gy)
    if r > 1e-6:
        m *= 1.0 - 0.65 * max(0.0, gy / r) ** 1.4
    return m

PEAKS = []
for i in range(7):
    ang = 2 * pi * i / 7 + 0.5 * (r01(i, 3, 71) - 0.5)
    rad = 0.36 * SIZE + 0.13 * SIZE * r01(i, 4, 73)
    ph = 0.052 * SIZE + 0.050 * SIZE * r01(i, 5, 79)
    PEAKS.append((rad * cos(ang), rad * sin(ang), ph, 0.10 * SIZE + 0.04 * SIZE * r01(i, 6, 83)))

def height(gx, gy):
    r = hypot(gx, gy)
    fr = flat_radius(gx, gy)
    if r <= fr:
        return 0.0
    t = ss((r - fr) / 26.0)
    mm = mountain_mask(gx, gy)
    far = ss((r - 86.0) / 70.0)
    plain = max(0.0, (fbm(gx * 0.012, gy * 0.012, 3, 21) - 0.30)) * 6.2
    mountain = (ridge(gx * 0.0055, gy * 0.0055, 4, 7) ** 1.5) * (0.088 * SIZE) * mm * far
    pk = 0.0
    for (px, py, ph, pr) in PEAKS:
        pk += ph * exp(-(((gx - px) ** 2 + (gy - py) ** 2) / (2 * pr * pr)))
    pk *= mm * far
    h = t * plain + mountain + pk
    rim = ss((r - 0.42 * SIZE) / (0.09 * SIZE))
    h += rim * (0.045 * SIZE) * max(mm, 0.12)
    # 相机侧轻压
    if r > 1e-6:
        d = (gx / r) * 0.7071 + (gy / r) * -0.7071
        h *= 1.0 - 0.18 * max(0.0, d) ** 1.5
    return h

# ---------------------------------------------------------------- 分阶段构建
STATE = {"step": 0, "grid": None, "objs": []}

def cleanup():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)

def build_flat():
    """第 1 步：平地网格（你会看到一张平板，可玩区 y=0）"""
    me = bpy.data.meshes.new("Terrain_flat")
    verts = []
    for j in range(N + 1):
        for i in range(N + 1):
            verts.append((-HALF + i * CELL, -HALF + j * CELL, 0.0))
    faces = []
    for j in range(N):
        for i in range(N):
            a = j * (N + 1) + i
            faces.append((a, a + 1, a + N + 2, a + N + 1))
    me.from_pydata(verts, [], faces)
    me.update()
    ob = bpy.data.objects.new("Terrain", me)
    bpy.context.scene.collection.objects.link(ob)
    STATE["objs"].append(ob)
    STATE["grid"] = ob

def displace(fn):
    """第 2/3 步：按高度函数搬顶点（视口会实时变形）"""
    ob = STATE["grid"]
    me = ob.data
    for v in me.vertices:
        v.co.z = fn(v.co.x, v.co.y)
    me.update()

def add_material_zones():
    """第 4 步：按高度/坡度刷 4 档色块，打开就能看到分区"""
    ob = STATE["grid"]
    me = ob.data
    me.materials.clear()
    tones = [("#4A4E52", "zone_plaza"), ("#403E36", "zone_wilds"),
             ("#59524A", "zone_rock"), ("#474239", "zone_rockdark")]
    mat_list = []
    for hexc, name in tones:
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        h = hexc.lstrip('#')
        rgb = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
        rgb = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
        m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*rgb, 1)
        m.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.9
        me.materials.append(m)
        mat_list.append(m)
    for p in me.polygons:
        c = p.center
        r = hypot(c.x, c.y)
        if r < 20:
            p.material_index = 0
        elif c.z < 2.0:
            p.material_index = 1
        elif p.normal.z < 0.65:
            p.material_index = 3
        else:
            p.material_index = 2
        p.use_smooth = False
    me.update()

def add_props():
    """第 5 步：撒巨石（低模二十面体）"""
    ico = [(-1, 1.618, 0), (1, 1.618, 0), (-1, -1.618, 0), (1, -1.618, 0),
           (0, -1, 1.618), (0, 1, 1.618), (0, -1, -1.618), (0, 1, -1.618),
           (1.618, 0, -1), (1.618, 0, 1), (-1.618, 0, -1), (-1.618, 0, 1)]
    ico_f = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
             (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
             (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
             (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    me = bpy.data.meshes.new("Rocks")
    V = []; F = []
    rd = random.Random(SEED)
    for k in range(40):
        a = rd.uniform(0, 2 * pi); r = rd.uniform(60, 150)
        gx, gy = cos(a) * r, sin(a) * r
        h = height(gx, gy)
        s = rd.uniform(1.6, 3.4)
        off = len(V)
        for (vx, vy, vz) in ico:
            kk = 0.78 + 0.4 * r01(int(vx * 97), int(vz * 97) + k, 9001)
            V.append((gx + vx * kk * s, gy + vy * kk * s, h + vz * kk * s * 0.7))
        F += [[i + off for i in f] for f in ico_f]
    me.from_pydata(V, [], F)
    me.update()
    m = bpy.data.materials.new("boulder")
    m.use_nodes = True
    m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.09, 0.085, 0.07, 1)
    me.materials.append(m)
    ob = bpy.data.objects.new("Rocks", me)
    bpy.context.scene.collection.objects.link(ob)
    STATE["objs"].append(ob)

def add_light_camera():
    ld = bpy.data.lights.new("Sun", type='SUN')
    ld.energy = 4.5
    ld.angle = radians(1.0)
    lo = bpy.data.objects.new("Sun", ld)
    lo.rotation_euler = (radians(50), 0, radians(-35))
    bpy.context.scene.collection.objects.link(lo)

    cd = bpy.data.cameras.new("Cam")
    cd.type = 'ORTHO'; cd.ortho_scale = 340
    cam = bpy.data.objects.new("Cam", cd)
    cam.rotation_euler = (radians(90 - 40), 0, radians(45))
    fwd = cam.rotation_euler.to_matrix() @ Vector((0, 0, -1))
    cam.location = Vector((0, 0, 8)) - fwd * 420
    bpy.context.scene.collection.objects.link(cam)
    bpy.context.scene.camera = cam

STEPS = [
    ("1/5 建网格平板（可玩区 y=0）", build_flat),
    ("2/5 抬升山地（叠加山脊噪声）", lambda: displace(height)),
    ("3/5 添加碎面抖动（低模感）", lambda: displace(lambda x, y: height(x, y) +
        (0.35 * (r01(int((x + HALF) / CELL), int((y + HALF) / CELL), 4242) - 0.5) * 2
         if 2.0 < height(x, y) < 22.0 else 0.0))),
    ("4/5 刷分区材质（城内/荒地/岩体/陡壁）", add_material_zones),
    ("5/5 撒巨石 + 灯光相机", lambda: (add_props(), add_light_camera())),
]

def tick():
    i = STATE["step"]
    if i >= len(STEPS):
        print("=== 构建完成。按小键盘 7 顶视 / 5 正交 查看 ===")
        return None
    label, fn = STEPS[i]
    print(f"[演示] {label}")
    fn()
    STATE["step"] += 1
    bpy.context.view_layer.update()
    return 0.35

cleanup()
print("=== 地形分层构建演示开始（共 5 步，每步 0.35s）===")
bpy.app.timers.register(tick, first_interval=0.1)