# -*- coding: utf-8 -*-
"""
《城墙尸潮》2.5D 大地图 · 程序化低模地形生成器 v2
==================================================

v1 -> v2 修复（v1 的视觉验收不合格，问题全部来自代码）：
 1) 同心圆靶心：城内石板/墙影带原来写死 r<18.5 / r<25 的正圆。
    v2 改为噪声扰动的边界，且墙影带只沿 150° 墙弧分布（不再是一整圈）。
 2) 山体像碎石场：jitter 0.95 配 2.5m 网格 = 每个面独立随机倾斜。
    v2 降到 0.35，并改由**低频山脊**主导形体（ridge 频率 0.0115 -> 0.0055）。
 3) 整体过暗：材质按提案明度阶梯重排 + 渲染配光按游戏实际参数。
 4) 城内一片纯色：加石板铺装双色调（3.5m 网格），近景终于有细节。
 5) 平地/丘陵交界是硬环：加碎石带（48-62m）打断"火山口"边缘。
 6) 树看不见：加低模树冠，树干加粗 1.6x。

坐标：Blender Z-up，地面 (gx,gy) -> Godot (x, -z)，高度 -> Godot +Y
墙弧依据 core/game_state.gd::_build_wall：
    center = Vector2(sin(a), -cos(a)) * 18，a = t*150°，t ∈ [-0.5, 0.5]
    => 墙弧朝游戏 -Z 方向，跨越 ±75°
"""

import bpy, bmesh, math, random, json, sys, os
from math import hypot, exp, sin, cos, radians, atan2, pi, sqrt
from mathutils import Vector, Matrix

PARAMS = {
    "map_size": 320.0,
    "cell": 1.6,           # 游戏正交视野只有 26m，2.5m 一格太粗（只见 10 格）
    "chunks": 5,           # 320/5 = 64m 每块，1.6m -> 40 格/块
    "seed": 20261115,
    "flat_r": 58.0,        # 完全平坦半径基准
    "flat_jitter": 6.0,     # 平坦边界噪声幅度 => 实际最小 52m，必须 > scout_radius_max(46)
    "ramp": 26.0,           # 起坡过渡宽度
    "jitter": 0.35,         # 碎面幅度（v1 是 0.95，导致碎石感）
    "tex_meters": 9.0,
    "rocks": 55,
    "pebbles": 230,         # 过渡带碎石
    "trees": 150,
    "ruins": 10,
}

def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--out":   out = argv[i + 1]; i += 2
        elif a == "--size": PARAMS["map_size"] = float(argv[i + 1]); i += 2
        elif a == "--seed": PARAMS["seed"] = int(argv[i + 1]); i += 2
        elif a == "--cell": PARAMS["cell"] = float(argv[i + 1]); i += 2
        else: i += 1
    return out

OUT_PATH = parse_args()

MAP = PARAMS["map_size"]
CELL = PARAMS["cell"]
CHUNKS = PARAMS["chunks"]
SEED = PARAMS["seed"]
JITTER = PARAMS["jitter"]
TEX_M = PARAMS["tex_meters"]
N = int(round(MAP / CELL))
HALF = MAP / 2.0
CPC = N // CHUNKS
CHUNK_M = MAP / CHUNKS

# 游戏坐标 (x, z) -> Blender 地面 (gx, gy) = (x, -z)
# 相机位于游戏 +X+Z 象限 => Blender 地面 (+X, -Y)
CAM_DIR = (cos(radians(45.0)), -sin(radians(45.0)))
# 墙弧朝向：游戏 -Z => Blender +Y
WALL_DIR = (0.0, 1.0)
WALL_ARC_HALF = radians(150.0) * 0.5

# ============================ 噪声 ============================
def _hash(ix, iy, seed):
    n = (ix * 374761393 + iy * 668265263 + seed * 1442695041) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return (n ^ (n >> 16)) & 0x7FFFFFFF

def rnd01(ix, iy, seed):
    return _hash(ix, iy, seed) / 2147483647.0

def vnoise(x, y, seed):
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy
    u = fx * fx * (3.0 - 2.0 * fx)
    v = fy * fy * (3.0 - 2.0 * fy)
    a = rnd01(ix, iy, seed); b = rnd01(ix + 1, iy, seed)
    c = rnd01(ix, iy + 1, seed); d = rnd01(ix + 1, iy + 1, seed)
    return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v

def fbm(x, y, octaves, seed):
    s = 0.0; amp = 0.5; f = 1.0; nrm = 0.0
    for i in range(octaves):
        s += amp * vnoise(x * f, y * f, seed + i * 17)
        nrm += amp; amp *= 0.5; f *= 2.0
    return s / nrm

def ridged(x, y, octaves, seed):
    s = 0.0; amp = 0.5; f = 1.0; nrm = 0.0
    for i in range(octaves):
        n = vnoise(x * f, y * f, seed + i * 31)
        r = 1.0 - abs(2.0 * n - 1.0)
        s += amp * r * r
        nrm += amp; amp *= 0.5; f *= 2.0
    return s / nrm

def smoothstep(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)

# ============================ 高度场 ============================
# 主峰布点：低频、少量、远（让山脊有走向而不是一片疙瘩）
PEAKS = []
for i in range(7):
    ang = 2.0 * pi * i / 7.0 + 0.5 * (rnd01(i, 3, 71 + SEED % 97) - 0.5)
    rad = 0.36 * MAP + 0.13 * MAP * rnd01(i, 4, 73 + SEED % 89)
    ph = 0.052 * MAP + 0.050 * MAP * rnd01(i, 5, 79 + SEED % 83)
    PEAKS.append((rad * cos(ang), rad * sin(ang), ph,
                  0.10 * MAP + 0.04 * MAP * rnd01(i, 6, 83 + SEED % 79)))

def near_weight(gx, gy):
    """相机侧轻微压低（0.18 强度）：只用来看得见战场，
    不再用来"塑形"——之前 0.40 的强力压低和山体掩码互相抵消，
    结果山全堆在没被压低的方向，看上去还是个封闭圆碗。"""
    r = hypot(gx, gy)
    if r < 1e-6:
        return 1.0
    d = (gx / r) * CAM_DIR[0] + (gy / r) * CAM_DIR[1]
    return 1.0 - 0.18 * max(0.0, d) ** 1.5

def flat_radius(gx, gy):
    """可玩区边界：噪声扰动 + **朝敌人来向开口**。

    城墙是 150° 弧，弧面朝游戏 -Z（Blender +Y）。敌人从墙外攻来，
    所以 +Y 这一侧必须是开阔战场，山体后退而不是围成一圈 ——
    否则整张图就是一个封闭圆碗（v007/v008 的观感问题）。
    """
    n = fbm(gx * 0.013, gy * 0.013, 3, 501 + SEED % 101)
    base = PARAMS["flat_r"] + PARAMS["flat_jitter"] * (n - 0.5) * 2.0
    r = hypot(gx, gy)
    if r < 1e-6:
        return base
    # 与 +Y（墙外/战场方向）的夹角余弦，平方后只让正对的一侧开口
    d = gy / r
    openness = max(0.0, d) ** 2
    return base + 34.0 * openness

def mountain_mask(gx, gy):
    """低频大尺度掩码：决定"这片区域是山地"还是"开阔平原"。

    这是 v007-v009 反复失败的根本修复点：只要用"到原点距离"控高，
    数学上必然生成一个封闭圆碗。真实地貌是**山成片出现、其余是平原**。
    同时敌人来向（+Y，墙弧外侧）强制压低为开阔战场。
    """
    n = fbm(gx * 0.0042, gy * 0.0042, 3, 901 + SEED % 53)
    m = smoothstep((n - 0.385) / 0.20)
    r = hypot(gx, gy)
    if r > 1e-6:
        d = gy / r
        m *= (1.0 - 0.65 * max(0.0, d) ** 1.4)   # +Y 战场方向保持开阔
    return m

# ============================ 河流 ============================
# 硬约束：可玩区 r<=56m 必须绝对 y=0，所以河道整体外移到最近 88m 处。
# 河道 = 河床下切 + 两岸过渡 + 一条独立水面 ribbon（随路径缓慢下降，像真河）。
RIVER_W = 18.0            # 河道宽度
RIVER_BANK = 7.0          # 河岸过渡宽度
RIVER_DEPTH = 3.4         # 河床相对当地地面下切
RIVER_LEVEL_START = 9.0   # 起点水面高度（山侧）
RIVER_LEVEL_END = -1.2    # 终点水面高度（平原侧）

RIVER_CTRL = [(-150.0, -105.0), (-110.0, -55.0), (-88.0, -5.0),
              (-86.0, 45.0), (-100.0, 90.0), (-140.0, 125.0)]

def _catmull(p0, p1, p2, p3, t):
    t2 = t * t; t3 = t2 * t
    return 0.5 * ((2.0 * p1) + (-p0 + p2) * t +
                  (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
                  (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)

def _river_samples(n_per_seg=26):
    pts = [RIVER_CTRL[0]] + list(RIVER_CTRL) + [RIVER_CTRL[-1]]
    out = []
    for i in range(len(pts) - 3):
        for k in range(n_per_seg):
            t = k / float(n_per_seg)
            x = _catmull(pts[i][0], pts[i + 1][0], pts[i + 2][0], pts[i + 3][0], t)
            y = _catmull(pts[i][1], pts[i + 1][1], pts[i + 2][1], pts[i + 3][1], t)
            out.append((x, y))
    out.append(pts[-2])
    return out

RIVER_PTS = _river_samples()
_rlen = [0.0]
for _i in range(1, len(RIVER_PTS)):
    dx = RIVER_PTS[_i][0] - RIVER_PTS[_i - 1][0]
    dy = RIVER_PTS[_i][1] - RIVER_PTS[_i - 1][1]
    _rlen.append(_rlen[-1] + (dx * dx + dy * dy) ** 0.5)
RIVER_TOTAL = _rlen[-1] or 1.0
# RIVER_LEVEL 不能在这里硬编码：它必须由**当地地形**决定，
# 否则水面会在某些段钻到地下 / 浮在空中（v001 就踩了这个坑）。
# 实际计算放在 base_height_raw 定义之后。
RIVER_LEVEL = []

def nearest_river(gx, gy):
    """返回 (到河道中线距离, 该处水面高度)。河道整体在远处，暴力最近点足够快。"""
    best = 1e18; best_i = 0
    for i, (px, py) in enumerate(RIVER_PTS):
        d2 = (gx - px) ** 2 + (gy - py) ** 2
        if d2 < best:
            best = d2; best_i = i
    return best ** 0.5, RIVER_LEVEL[best_i]

def base_height_raw(gx, gy):
    """不含河道的地形：底层缓丘 + 上层山（掩码 x 远处双门控）。"""
    r = hypot(gx, gy)
    fr = flat_radius(gx, gy)
    if r <= fr:
        return 0.0
    t = smoothstep((r - fr) / PARAMS["ramp"])
    plain = max(0.0, (fbm(gx * 0.012, gy * 0.012, 3, 21) - 0.30)) * 6.2
    mm = mountain_mask(gx, gy)
    far = smoothstep((r - 86.0) / 70.0)
    ridge = ridged(gx * 0.0055, gy * 0.0055, 4, 7 + SEED % 61)
    mountain = (ridge ** 1.5) * (0.088 * MAP) * mm * far
    pk = 0.0
    for (px, py, ph, pr) in PEAKS:
        d2 = (gx - px) ** 2 + (gy - py) ** 2
        pk += ph * exp(-d2 / (2.0 * pr * pr))
    pk *= mm * far
    h = t * plain + mountain + pk
    rim = smoothstep((r - 0.42 * MAP) / (0.09 * MAP))
    h += rim * (0.045 * MAP) * max(mm, 0.12)
    return h * near_weight(gx, gy)

# ---- 水面剖面：由当地地形推导，保证水永远在地面以下 ----
_raw = [base_height_raw(px, py) for (px, py) in RIVER_PTS]
_sm = []
_win = 6
for i in range(len(_raw)):
    lo = max(0, i - _win); hi = min(len(_raw), i + _win + 1)
    _sm.append(sum(_raw[lo:hi]) / float(hi - lo))
# 河道处的"水面" = 平滑地面 - 1.6m（下切 1.6m 形成河岸可见的落差）
_levels = [max(-2.0, _v - 1.6) for _v in _sm]
# 单调不增：水不能逆流上山
for i in range(1, len(_levels)):
    if _levels[i] > _levels[i - 1]:
        _levels[i] = _levels[i - 1]
RIVER_LEVEL = _levels

def base_height(gx, gy):
    """地形最终高度：河道内强制为绝对河床（= 水面 - 深度），岸边平滑过渡。"""
    h = base_height_raw(gx, gy)
    d, wl = nearest_river(gx, gy)
    half = RIVER_W * 0.5
    if d >= half + RIVER_BANK:
        return h
    bed = wl - RIVER_DEPTH
    if d <= half:
        return bed
    u = smoothstep((d - half) / RIVER_BANK)
    return bed * (1.0 - u) + max(h, bed) * u

def grid_height(gi, gj):
    gx = -HALF + gi * CELL
    gy = -HALF + gj * CELL
    h = base_height(gx, gy)
    # 抖动只作用于中低海拔：高山保持整块形面，避免"碎石堆"观感
    if 2.0 < h < 22.0:
        amp = JITTER * smoothstep((h - 2.0) / 8.0) * (1.0 - smoothstep((h - 14.0) / 8.0))
        h += amp * (rnd01(gi, gj, 4242 + SEED % 71) - 0.5) * 2.0
    return gx, gy, h

def surface_at(gx, gy):
    """任意点的真实地面高度（道具贴合三角面，不浮空不埋没）。"""
    fx = (gx + HALF) / CELL
    fy = (gy + HALF) / CELL
    gi = max(0, min(N - 1, int(math.floor(fx))))
    gj = max(0, min(N - 1, int(math.floor(fy))))
    u = fx - gi; v = fy - gj
    cx = gi // CPC; i = gi - cx * CPC
    cy = gj // CPC; j = gj - cy * CPC
    ha = grid_height(gi, gj)[2]
    hb = grid_height(gi + 1, gj)[2]
    hc = grid_height(gi, gj + 1)[2]
    hd = grid_height(gi + 1, gj + 1)[2]
    if ((i * 7 + j * 13 + cx * 3 + cy * 5) % 2) == 0:
        if v <= u: return ha + u * (hb - ha) + v * (hd - hb)
        return ha + v * (hc - ha) + u * (hd - hc)
    if u + v <= 1.0: return ha + u * (hb - ha) + v * (hc - ha)
    return hd + (1 - u) * (hb - hd) + (1 - v) * (hc - hd)



# ============================ 材质 ============================
def srgb(hexstr):
    h = hexstr.lstrip('#')
    out = []
    for i in (0, 2, 4):
        c = int(h[i:i + 2], 16) / 255.0
        out.append(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4)
    return tuple(out)

PALETTE = [
    ("Terrain_PlazaA",     "#575147", 0.92),   # 0 城内石板亮格（靠铺装纹理区分，不靠明度大跳）
    ("Terrain_PlazaB",     "#4E4940", 0.92),   # 1 城内石板暗格
    ("Terrain_PlazaC",     "#5F594E", 0.92),   # 2 城内石板亮块（第三档，读作石材色差）
    ("Terrain_Wilds",      "#3F3D35", 0.90),   # 3 城外荒地（暖灰，L≈24）
    ("Terrain_Scrub",      "#454A3A", 0.88),   # 4 枯草（低饱和灰绿，别读成草坪）
    ("Terrain_Rock",       "#59524A", 0.86),   # 5 岩体（暖褐灰 L≈33）
    ("Terrain_RockDark",   "#474239", 0.82),   # 6 陡壁 / 背光面（别黑成一块）
    ("Terrain_RockLight",  "#7C7365", 0.80),   # 7 山脊亮面（暖亮 L≈47）
    ("Terrain_RockBand",   "#4A443C", 0.85),   # 8 岩层条带
    ("Terrain_RiverBed",   "#3A3E36", 0.62),   # 9 河床湿砾石（暗、略亮面）
    ("Prop_Boulder",       "#5E574E", 0.84),   # 10 巨石
    ("Prop_TreeSilhouette","#33302A", 0.95),   # 11 枯树干
    ("Prop_RuinStone",     "#857C6E", 0.80),   # 12 残墙包边石
    ("Prop_RuinEarth",     "#7A6248", 0.88),   # 13 残墙夯土
    ("Prop_TreeCanopy",    "#3E4434", 0.90),   # 14 树冠（暗橄榄绿）
    ("Water_River",        "#2A3A44", 0.16),   # 15 河水（暗青灰，低粗糙=水膜感）
]
TERRAIN_MATS = 10
MAT_RIVERBED = 9
MAT_BOULDER = 10
MAT_TRUNK = 11
MAT_RUIN = 12
MAT_CANOPY = 14
MAT_WATER = 15

def plaza_radius(gx, gy):
    # 两层噪声：大起伏 + 细节，避免边界变成规整多边形
    n = fbm(gx * 0.021, gy * 0.021, 2, 777)
    n2 = fbm(gx * 0.085, gy * 0.085, 2, 779)
    return 19.5 + 3.4 * (n - 0.5) * 2.0 + 1.1 * (n2 - 0.5) * 2.0

# 主光方向（光线传播方向，用于岩石按朝光/背光分色）
SUN_ROT = (radians(50.0), 0.0, radians(-35.0))
_rm = Matrix.Rotation(SUN_ROT[2], 3, 'Z') @ Matrix.Rotation(SUN_ROT[0], 3, 'X')
SUN_FROM = -(_rm @ Vector((0.0, 0.0, -1.0)))     # 光的来向（单位向量）

def classify(gx, gy, h, nz, normal=None):
    r = hypot(gx, gy)
    pr = plaza_radius(gx, gy)
    if r < pr:
        # 不要用规则方格（4.5m 格子叠在三角面上会变成大菱形图案，
        # 近景读成"抽象地毯"）；低频三档才读成石材色差。
        n = fbm(gx * 0.055, gy * 0.055, 2, 881)
        if n < 0.40:
            return 1
        if n > 0.62:
            return 2
        return 0
    # 河床：水面以下 + 河道范围内 -> 湿砾石
    rd, wl = nearest_river(gx, gy)
    if h < wl + 0.55 and rd < RIVER_W * 0.5 + RIVER_BANK * 0.8:
        return MAT_RIVERBED
    if h < 1.8:
        # 荒地/枯草：用中频噪声，边界碎一点，避免 2.5m 网格的大台阶
        n1 = fbm(gx * 0.026, gy * 0.026, 3, 211) + 0.14 * fbm(gx * 0.09, gy * 0.09, 2, 213)
        return 4 if n1 > 0.68 else 3
    if h < 6.0 and nz > 0.82:
        n2 = fbm(gx * 0.030, gy * 0.030, 2, 223)
        return 4 if n2 > 0.74 else 3
    # 朝光面判定：山体明暗必须来自真实坡向，否则一块灰塑料
    lit = 0.0
    if normal is not None:
        lit = normal.dot(SUN_FROM)
    t = fbm(gx * 0.013, gy * 0.013, 2, 555)
    if nz < 0.50:
        return 6                                  # 陡壁
    if nz < 0.62:
        return 6 if lit < 0.05 else 5             # 陡坡：背光暗 / 朝光岩体
    if h > 0.20 * MAP and lit > 0.42 and nz > 0.74:
        return 7                                  # 山脊受光面
    if lit < -0.10 and t < 0.55:
        return 6                                  # 背光大面
    if t < 0.36:
        return 6
    if t < 0.56:
        return 8
    if t < 0.72:
        return 5
    if lit > 0.30:
        return 7
    return 5

# ============================ 建地形 ============================
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.unit_settings.system = 'METRIC'

mats = []
for name, hexc, rough in PALETTE:
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes.get("Principled BSDF")
    b.inputs["Base Color"].default_value = (*srgb(hexc), 1.0)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = 0.0
    mats.append(m)

terrain_coll = bpy.data.collections.new("Terrain")
scene.collection.children.link(terrain_coll)
mat_area = [0.0] * len(PALETTE)
tri_total = 0

for cy_ in range(CHUNKS):
    for cx_ in range(CHUNKS):
        verts = []; faces = []
        gi0 = cx_ * CPC; gj0 = cy_ * CPC
        for j in range(CPC + 1):
            for i in range(CPC + 1):
                verts.append(grid_height(gi0 + i, gj0 + j))
        row = CPC + 1
        for j in range(CPC):
            for i in range(CPC):
                a = j * row + i; b = a + 1; c = a + row; d = c + 1
                if ((i * 7 + j * 13 + cx_ * 3 + cy_ * 5) % 2) == 0:
                    faces.append((a, b, d)); faces.append((a, d, c))
                else:
                    faces.append((a, b, c)); faces.append((b, d, c))
        me = bpy.data.meshes.new(f"TerrainMesh_{cx_:02d}_{cy_:02d}")
        me.from_pydata(verts, [], faces)
        me.validate(); me.update()
        uv = me.uv_layers.new(name="UVMap")
        for poly in me.polygons:
            for li in poly.loop_indices:
                vx, vy, vz = me.vertices[me.loops[li].vertex_index].co
                uv.data[li].uv = (vx / TEX_M, vy / TEX_M)
        for m in mats[:TERRAIN_MATS]:
            me.materials.append(m)
        for poly in me.polygons:
            c = poly.center
            idx = classify(c.x, c.y, c.z, poly.normal.z, poly.normal)
            poly.material_index = idx
            poly.use_smooth = False
            mat_area[idx] += poly.area
        ob = bpy.data.objects.new(f"Terrain_Chunk_{cx_:02d}_{cy_:02d}", me)
        terrain_coll.objects.link(ob)
        tri_total += len(faces)

# ============================ 道具 ============================
props_coll = bpy.data.collections.new("Props")
scene.collection.children.link(props_coll)

ICO_V = [(-1, 1.618, 0), (1, 1.618, 0), (-1, -1.618, 0), (1, -1.618, 0),
         (0, -1, 1.618), (0, 1, 1.618), (0, -1, -1.618), (0, 1, -1.618),
         (1.618, 0, -1), (1.618, 0, 1), (-1.618, 0, -1), (-1.618, 0, 1)]
ICO_F = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
         (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
         (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
         (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]

def rock_geo(seed, sx, sy, sz):
    vs = []
    for (vx, vy, vz) in ICO_V:
        k = 0.78 + 0.40 * rnd01(int(vx * 97), int(vz * 97) + seed, 9001)
        vs.append(Vector((vx * k * sx, vy * k * sy, vz * k * sz)))
    return vs, [list(f) for f in ICO_F]

def prism_geo(h, r0, r1, sides=6):
    vs = []; fs = []
    for (z, rad) in [(0.0, r0), (h, r1)]:
        for k in range(sides):
            a = 2.0 * pi * k / sides
            vs.append(Vector((cos(a) * rad, sin(a) * rad, z)))
    for k in range(sides):
        a0 = k; a1 = (k + 1) % sides
        fs.append([a0, a1, a1 + sides, a0 + sides])
    fs.append(list(range(sides, 2 * sides)))
    return vs, fs

def tree_geo(seed):
    """枯树 + 低模树冠：俯视能读出"树"，不再是一根细线。
    返回 (verts, faces, per_face_material)。"""
    rd = random.Random(seed)
    h = rd.uniform(6.5, 11.0)
    trunk_r = rd.uniform(0.40, 0.58)
    vs = []; fs = []; fmat = []
    tv, tf = prism_geo(h * 0.80, trunk_r, trunk_r * 0.45, sides=6)
    vs += tv; fs += tf
    fmat += [MAT_TRUNK] * len(tf)                      # 树干 / 枯枝：剪影色
    # 树冠：三层递减排布，形成低模"枯树冠"，俯视有体量
    cr = rd.uniform(2.8, 3.9)
    for k, (zl, rl) in enumerate([(h * 0.46, cr),
                                  (h * 0.60, cr * 0.74),
                                  (h * 0.72, cr * 0.46)]):
        cv, cf = prism_geo(rd.uniform(0.9, 1.5), rl, rl * 0.55, sides=6)
        m = Matrix.Translation(Vector((rd.uniform(-0.7, 0.7), rd.uniform(-0.7, 0.7), zl)))
        off = len(vs)
        vs += [m @ v for v in cv]
        fs += [[i + off for i in f] for f in cf]
        fmat += [MAT_CANOPY] * len(cf)                  # 树冠
    # 枯枝：2-3 根细棱柱，从树冠缝隙探出
    for _ in range(rd.randint(2, 3)):
        bh = h * rd.uniform(0.55, 0.80)
        bv, bf = prism_geo(rd.uniform(1.6, 3.0), 0.12, 0.03, sides=4)
        m = (Matrix.Translation(Vector((0, 0, bh))) @
             Matrix.Rotation(rd.uniform(0, 2 * pi), 4, 'Z') @
             Matrix.Rotation(radians(rd.uniform(50, 72)), 4, 'Y'))
        off = len(vs)
        vs += [m @ v for v in bv]
        fs += [[i + off for i in f] for f in bf]
        fmat += [MAT_TRUNK] * len(bf)
    return vs, fs, fmat

def ruin_geo(seed):
    rd = random.Random(seed)
    L = rd.uniform(4.0, 9.5); T = rd.uniform(0.8, 1.3)
    segs = rd.randint(3, 5)
    vs = []; fs = []
    for i in range(segs + 1):
        x = -L / 2 + L * i / segs
        top = rd.uniform(1.0, 2.8) if 0 < i < segs else rd.uniform(0.4, 1.5)
        j = rd.uniform(-0.2, 0.2)
        vs += [Vector((x, -T / 2, 0)), Vector((x, T / 2, 0)),
               Vector((x + j, -T / 2, top)), Vector((x + j, T / 2, top))]
    for i in range(segs):
        b = i * 4; n = b + 4
        fs.append([b, n, n + 1, b + 1])
        fs.append([b + 2, b + 3, n + 3, n + 2])
        fs.append([b, b + 2, n + 2, n])
        fs.append([b + 1, n + 1, n + 3, b + 3])
    fs.append([0, 1, 3, 2])
    e = segs * 4
    fs.append([e, e + 2, e + 3, e + 1])
    return vs, fs

def build_props(name, items):
    V = []; F = []; MI = []; used = set()
    for (vs, fs, m, midx) in items:
        off = len(V)
        V += [m @ v for v in vs]
        for k, f in enumerate(fs):
            F.append([i + off for i in f])
            mi = midx[k] if isinstance(midx, (list, tuple)) else midx
            MI.append(mi); used.add(mi)
    used = sorted(used)
    slot = {mi: k for k, mi in enumerate(used)}
    me = bpy.data.meshes.new(name + "_mesh")
    me.from_pydata([tuple(v) for v in V], [], F)
    me.validate(); me.update()
    for mi in used:
        me.materials.append(mats[mi])
    for poly, mi in zip(me.polygons, MI):
        poly.material_index = slot[mi]
        poly.use_smooth = False
    bm = bmesh.new(); bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me); bm.free(); me.update()
    ob = bpy.data.objects.new(name, me)
    props_coll.objects.link(ob)
    return ob, len(F)

rd = random.Random(SEED)
placed = []

def sample_point(rmin, rmax, clearance, tries=1200, want=None):
    for _ in range(tries):
        a = rd.uniform(0, 2 * pi)
        r = rd.uniform(rmin, rmax)
        gx = cos(a) * r; gy = sin(a) * r
        if not (-HALF + 5 < gx < HALF - 5 and -HALF + 5 < gy < HALF - 5):
            continue
        h = surface_at(gx, gy)
        if want is not None and not want(gx, gy, h):
            continue
        if all((gx - px) ** 2 + (gy - py) ** 2 >= clearance ** 2 for (px, py) in placed):
            placed.append((gx, gy))
            return gx, gy, h
    return None

rock_items = []
def rock_ok(gx, gy, h):
    # 巨石只长在山地（掩码高），且避开河道与可玩区
    if nearest_river(gx, gy)[0] < RIVER_W * 0.5 + 6.0:
        return False
    return h > 6.0 and mountain_mask(gx, gy) > 0.45
for i in range(PARAMS["rocks"]):
    p = sample_point(64.0, 0.47 * MAP, clearance=16.0, want=rock_ok)
    if p is None:
        continue
    gx, gy, h = p
    s = rd.uniform(1.8, 3.6)
    vs, fs = rock_geo(i, s, s * rd.uniform(0.75, 1.0), s * rd.uniform(0.6, 0.95))
    m = Matrix.Translation(Vector((gx, gy, h - s * 0.50))) @ Matrix.Rotation(rd.uniform(0, 2 * pi), 4, 'Z')
    rock_items.append((vs, fs, m, MAT_BOULDER))

pebble_items = []
for i in range(PARAMS["pebbles"]):
    # 碎石带：坡脚密集、远处稀疏；不入可玩区（保护战场可读性）
    a = rd.uniform(0, 2 * pi)
    r = 58.0 + 46.0 * (rd.random() ** 1.7)
    gx = cos(a) * r; gy = sin(a) * r
    if not (-HALF + 5 < gx < HALF - 5 and -HALF + 5 < gy < HALF - 5):
        continue
    if nearest_river(gx, gy)[0] < RIVER_W * 0.5 + 2.0:
        continue
    h = surface_at(gx, gy)
    s = rd.uniform(0.30, 1.05)
    vs, fs = rock_geo(50000 + i, s, s * rd.uniform(0.8, 1.0), s * rd.uniform(0.45, 0.75))
    m = Matrix.Translation(Vector((gx, gy, h - s * 0.52))) @ Matrix.Rotation(rd.uniform(0, 2 * pi), 4, 'Z')
    pebble_items.append((vs, fs, m, MAT_BOULDER))

tree_items = []
def tree_ok(gx, gy, h):
    if nearest_river(gx, gy)[0] < RIVER_W * 0.5 + 7.0:
        return False
    # 树长在平缓地势；可玩区（r<60）留空给战场
    return h < 9.0 and mountain_mask(gx, gy) < 0.75 and hypot(gx, gy) > 60.0

# 成丛分布：先撒 22 个簇心，再在簇内散 4-10 棵。
# 均匀撒点会读成"撒芝麻"，成丛才有自然植被的疏密节奏。
clusters = []
for _ in range(22):
    c = sample_point(64.0, 0.46 * MAP, clearance=17.0)
    if c is not None:
        clusters.append(c)
ti = 0
for (cx0, cy0, _ch) in clusters:
    for _ in range(rd.randint(4, 10)):
        ti += 1
        if len(tree_items) >= PARAMS["trees"]:
            break
        ang = rd.uniform(0, 2 * pi)
        rad = abs(rd.gauss(0.0, 8.5))
        gx = cx0 + cos(ang) * rad
        gy = cy0 + sin(ang) * rad
        if not (-HALF + 5 < gx < HALF - 5 and -HALF + 5 < gy < HALF - 5):
            continue
        h = surface_at(gx, gy)
        if not tree_ok(gx, gy, h):
            continue
        vs, fs, fmat = tree_geo(7000 + ti)
        m = Matrix.Translation(Vector((gx, gy, h - 0.35))) @ Matrix.Rotation(rd.uniform(0, 2 * pi), 4, 'Z')
        tree_items.append((vs, fs, m, fmat))

ruin_items = []
for i in range(PARAMS["ruins"]):
    p = sample_point(64.0, 0.38 * MAP, clearance=14.0,
                     want=lambda gx, gy, h: 1.0 < h < 14.0 and
                     nearest_river(gx, gy)[0] > RIVER_W * 0.5 + 12.0)
    if p is None:
        continue
    gx, gy, h = p
    vs, fs = ruin_geo(9000 + i)
    m = Matrix.Translation(Vector((gx, gy, h - 0.3))) @ Matrix.Rotation(rd.uniform(0, 2 * pi), 4, 'Z')
    ruin_items.append((vs, fs, m, MAT_RUIN))

n_rock = len(rock_items); n_peb = len(pebble_items)
n_tree = len(tree_items); n_ruin = len(ruin_items)
_, t_rock = build_props("Props_Rocks", rock_items)
_, t_peb = build_props("Props_Pebbles", pebble_items)
_, t_tree = build_props("Props_Trees", tree_items)
_, t_ruin = build_props("Props_Ruins", ruin_items)

# ============================ 河面 ============================
# 独立 ribbon 网格：沿河道中线，宽度 = RIVER_W，高度取该处水面高度。
# 水面比河床高一点点，露在河道里；地形已经下切到位，所以不会穿插。
def build_water():
    half = RIVER_W * 0.5
    V = []; F = []
    for i, (px, py) in enumerate(RIVER_PTS):
        # 法线方向（垂直于路径切线）
        if i == 0:
            tx, ty = RIVER_PTS[1][0] - px, RIVER_PTS[1][1] - py
        elif i == len(RIVER_PTS) - 1:
            tx, ty = px - RIVER_PTS[i - 1][0], py - RIVER_PTS[i - 1][1]
        else:
            tx = (RIVER_PTS[i + 1][0] - RIVER_PTS[i - 1][0]) * 0.5
            ty = (RIVER_PTS[i + 1][1] - RIVER_PTS[i - 1][1]) * 0.5
        ln = (tx * tx + ty * ty) ** 0.5 or 1.0
        nx, ny = -ty / ln, tx / ln
        # 河宽沿路径缓慢变化（自然河流宽窄不一，等宽会读成人工运河）
        wob = fbm(i * 0.055, 3.7, 2, 313)
        w = half * (0.62 + 0.22 * wob)
        # 水面轻微起伏（低模波纹），纯平会读成一块塑料板
        wob2 = 0.16 * sin(i * 0.62) + 0.10 * sin(i * 1.37 + 1.1)
        y = RIVER_LEVEL[i] + 0.10 + wob2
        V.append((px - nx * w, py - ny * w, y))
        V.append((px + nx * w, py + ny * w, y))
    for i in range(len(RIVER_PTS) - 1):
        a = i * 2
        F.append((a, a + 1, a + 3, a + 2))
    me = bpy.data.meshes.new("RiverWater_mesh")
    me.from_pydata(V, [], F)
    me.validate(); me.update()
    uv = me.uv_layers.new(name="UVMap")
    for poly in me.polygons:
        for li in poly.loop_indices:
            vx, vy, vz = me.vertices[me.loops[li].vertex_index].co
            uv.data[li].uv = (vx / TEX_M, vy / TEX_M)
    me.materials.append(mats[MAT_WATER])
    for p in me.polygons:
        p.use_smooth = False
    ob = bpy.data.objects.new("River_Water", me)
    props_coll.objects.link(ob)
    return ob, len(F)

_, t_water = build_water()

# ============================ 灯光 / 相机 ============================
world = bpy.data.worlds.new("DuskWorld")
scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes["Background"]
bg.inputs["Color"].default_value = (*srgb("#2E3640"), 1.0)
bg.inputs["Strength"].default_value = 0.36

sun_data = bpy.data.lights.new("Sun_Key", type='SUN')
sun_data.color = srgb("#B6C9DA")
sun_data.energy = 4.6
sun_data.angle = radians(1.0)
sun = bpy.data.objects.new("Sun_Key", sun_data)
sun.rotation_euler = SUN_ROT
scene.collection.objects.link(sun)

def add_cam(name, ortho, target, yaw_deg, pitch_deg, dist=260.0, clip_end=1800.0):
    cd = bpy.data.cameras.new(name)
    cd.type = 'ORTHO'; cd.ortho_scale = ortho
    cd.clip_start = 0.5; cd.clip_end = clip_end
    cam = bpy.data.objects.new(name, cd)
    cam.rotation_euler = (radians(90.0 - pitch_deg), 0.0, radians(yaw_deg))
    fwd = cam.rotation_euler.to_matrix() @ Vector((0, 0, -1))
    cam.location = Vector(target) - fwd * dist
    scene.collection.objects.link(cam)
    return cam

add_cam("Cam_Game_City", 26.0, (0.0, 0.0, 3.0), 45.0, 52.0)
add_cam("Cam_Game_Wide", 120.0, (0.0, 0.0, 6.0), 45.0, 52.0)
add_cam("Cam_Map_Top", MAP + 16.0, (0.0, 0.0, 0.0), 0.0, 90.0, dist=420.0)
add_cam("Cam_Iso_Overview", MAP * 0.96, (0.0, 0.0, 12.0), 45.0, 34.0, dist=580.0)
# 河流特写：镜头对准河道中段
_rx, _ry = RIVER_PTS[len(RIVER_PTS) // 2]
add_cam("Cam_River", 130.0, (_rx, _ry, 6.0), 45.0, 40.0, dist=320.0)

scene.camera = bpy.data.objects["Cam_Game_Wide"]
scene.render.engine = 'BLENDER_EEVEE'
scene.render.resolution_x = 1280
scene.render.resolution_y = 720
scene.view_settings.view_transform = 'AgX'
scene.view_settings.look = 'AgX - Medium High Contrast'
scene.view_settings.exposure = 0.9
scene.eevee.taa_render_samples = 48

# ============================ 导出 ============================
if OUT_PATH:
    base = os.path.splitext(OUT_PATH)[0]
    G = N + 1
    heights = []
    hmin, hmax = 1e9, -1e9
    for gj in range(G):
        for gi in range(G):
            h = grid_height(gi, gj)[2]
            heights.append(round(h, 4))
            hmin = min(hmin, h); hmax = max(hmax, h)
    with open(base + ".heights.json", "w", encoding="utf-8") as f:
        json.dump({
            "format": "godot-heightmap-v1",
            "map_size_m": MAP, "grid": G, "cell_m": CELL,
            "height_min": round(hmin, 4), "height_max": round(hmax, 4),
            "index_order": "row-major, rows increase toward Godot -z",
            "heights": heights,
        }, f)
    bpy.ops.wm.save_as_mainfile(filepath=OUT_PATH)

total = sum(mat_area) or 1.0
ys = sorted(v.co.z for ob in terrain_coll.objects for v in ob.data.vertices)
nzs = sorted(p.normal.z for ob in terrain_coll.objects for p in ob.data.polygons)
print("TERRAIN_SUMMARY " + json.dumps({
    "map_size_m": MAP, "cell_m": CELL, "seed": SEED, "jitter": JITTER,
    "terrain_triangles": tri_total,
    "total_triangles": tri_total + t_rock + t_peb + t_tree + t_ruin,
    "props": {"rocks": n_rock, "pebbles": n_peb, "trees": n_tree, "ruins": n_ruin},
    "height": {"min": round(ys[0], 2), "p50": round(ys[len(ys) // 2], 2),
               "p95": round(ys[int(len(ys) * 0.95)], 2), "max": round(ys[-1], 2)},
    "slope_normal_z_p10": round(nzs[int(len(nzs) * 0.10)], 3),
    "material_area_pct": {PALETTE[i][0]: round(100.0 * mat_area[i] / total, 2)
                          for i in range(TERRAIN_MATS)},
    "blend": OUT_PATH,
}, ensure_ascii=False))