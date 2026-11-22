class_name WorldBuilder
extends Node3D
## 表现层 · 世界装配：程序化生成地面、城墙、水晶、灯光。
## 只读 ConfigDB 与 GameState.snapshot()，不写任何逻辑状态。

var wall_nodes: Array = []
var crystal_node: Node3D
var crystal_diamond: Node3D
var crystal_material: StandardMaterial3D          # 旧占位（缺 GLB 时兜底）
var crystal_effects: Array = []                   # [{mat, base_albedo, base_emission}]
var wall_materials: Array = []
var wall_hover := -1               # 建设期光标命中的墙段（P0-7），-1 = 无
var wall_height := 3.5
var wall_thickness := 1.2

const WALL_COLOR := Color(0.55, 0.52, 0.46)
const WALL_HURT := Color(0.85, 0.35, 0.28)

## 场景贴图（缺图自动退回纯色，不影响可玩性）
const TEX_GROUND_WILDS := "res://art/assets/env/tex_ground_wilds_tile_v2.png"
const TEX_GROUND_PLAZA := "res://art/assets/env/tex_ground_plaza_tile_v2.png"
const TEX_SKY_DUSK := "res://art/assets/env/env_sky_dusk_v1.png"
## 一张地面贴图铺多少米。4m 时网格重复一眼可见（每 4m 一个同款方块），
## 抬到 9m 让单块纹理读成"地面起伏"而不是"地毯方块"。
const GROUND_TILE_METERS := 9.0

## ---- Blender 生成的大地图（320×320m，含平原/山地/河流） ----
## 生成器：art/assets/models/terrain/generate_terrain.py
## 可玩区半径 56m 内是绝对 y=0 的平面，与 core 的 2D 逻辑坐标完全对齐；
## 山地与河道全部在 60m 之外，不影响敌我贴地判定。
const TERRAIN_SCENE := "res://art/assets/models/terrain/terrain_map_v001_textured.glb"
## 关掉则回退到老的程序化平面 + 地面贴图（便于对比与兜底）
const USE_TERRAIN_MESH := true

## ---- 水晶核心（Blender 生成：菱形晶体 + 三级台阶底座，mdl_crystal_core_v1） ----
## 原点在底座地面（y=0），GEO_Crystal_Diamond 可单独浮动/缩放/受击变色
const CRYSTAL_SCENE := "res://art/assets/models/crystal/mdl_crystal_core_v1.glb"
const USE_CRYSTAL_MESH := true


func build(cfg: ConfigDB, snap: Dictionary) -> void:
	_clear()
	_add_environment()
	_add_ground(cfg)
	_add_wall(cfg, snap)
	_add_crystal(cfg)


func _clear() -> void:
	for c in get_children():
		c.queue_free()
	wall_nodes.clear()
	wall_materials.clear()
	crystal_node = null
	crystal_diamond = null
	crystal_material = null
	crystal_effects.clear()


func _add_environment() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.15
	light.shadow_enabled = true
	add_child(light)

	var env := Environment.new()
	# 天空：用暮色底图当背景。ambient_light_source 仍为 COLOR（不改成 SKY），
	# 否则整场亮度会被贴图均值带偏，配光参数要全部重调。
	var sky_tex := load(TEX_SKY_DUSK) as Texture2D
	if sky_tex != null:
		var pano := PanoramaSkyMaterial.new()
		pano.panorama = sky_tex
		var sky := Sky.new()
		sky.sky_material = pano
		env.background_mode = Environment.BG_SKY
		env.sky = sky
	else:
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.09, 0.10, 0.12)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.42, 0.46, 0.55)
	env.ambient_light_energy = 0.75
	env.fog_enabled = true
	env.fog_light_color = Color(0.12, 0.13, 0.16)
	env.fog_density = 0.012
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _add_ground(cfg: ConfigDB) -> void:
	# 优先用 Blender 大地图；缺失或不启用时回退到程序化平面
	if USE_TERRAIN_MESH and _add_terrain_mesh():
		return

	var size := cfg.num("world", "scout_radius_max", 46.0) * 2.6
	add_child(_ground_mesh(size, TEX_GROUND_WILDS, Color(0.20, 0.21, 0.20), 0.95))

	# 城墙内地面：换另一套贴图，给出"城内/城外"的视觉边界。
	# 用圆盘而不是方板：方板要完全盖住半径 22 的墙圈，边长就得 44，
	# 四个角会捅到 31m 处、把广场砖铺到城墙外面去（实拍可见）。圆盘贴合墙圈，两头都不漏。
	add_child(_ground_disc(22.0, TEX_GROUND_PLAZA, Color(0.26, 0.25, 0.23), 0.9))


## 地形 GLB 自带正确世界坐标（原点 = 水晶位置，y=0 = 逻辑地面），
## 不需要平移或缩放。它同时包含平原、山地、河流水面与树石道具（26 个节点）。
func _add_terrain_mesh() -> bool:
	var packed := load(TERRAIN_SCENE) as PackedScene
	if packed == null:
		push_warning("WorldBuilder: 地形 GLB 缺失，回退到程序化平面")
		return false
	var terrain: Node3D = packed.instantiate()
	terrain.name = "Terrain"
	add_child(terrain)
	return true


## 地面：贴图按"米"铺贴（uv1_scale），缺图退回纯色
func _ground_mesh(size: float, tex_path: String, fallback: Color, roughness: float) -> MeshInstance3D:
	var plane := PlaneMesh.new()
	plane.size = Vector2(size, size)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	_apply_ground_material(mi, tex_path, fallback, roughness, size)
	return mi


## 城内圆盘地面：CylinderMesh 的顶盖 UV 是 0..1 覆盖整个直径，铺贴数按直径算
func _ground_disc(radius: float, tex_path: String, fallback: Color, roughness: float) -> MeshInstance3D:
	var disc := CylinderMesh.new()
	disc.top_radius = radius
	disc.bottom_radius = radius
	disc.height = 0.04
	disc.radial_segments = 64
	disc.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = disc
	mi.position.y = 0.02
	_apply_ground_material(mi, tex_path, fallback, roughness, radius * 2.0)
	return mi


func _apply_ground_material(mi: MeshInstance3D, tex_path: String, fallback: Color,
		roughness: float, span: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = fallback
	mat.roughness = roughness
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var t := load(tex_path) as Texture2D
	if t != null:
		mat.albedo_texture = t
		mat.albedo_color = Color(1, 1, 1)
		var n := maxf(1.0, roundf(span / GROUND_TILE_METERS))
		mat.uv1_scale = Vector3(n, n, 1.0)
	mi.material_override = mat


func _add_wall(cfg: ConfigDB, snap: Dictionary) -> void:
	wall_height = cfg.num("world", "wall_height", 4.0)
	wall_thickness = cfg.num("world", "wall_thickness", 1.2)
	for seg in snap["wall"]:
		_add_wall_node(seg)


## 单独建一段（也用于玩家新建的墙段：sync_walls 发现索引超出时按需补节点）
## 城墙段低模（Blender 可复用段，见 art/blender-work/wall/README.md）：
## 段长 6.93m / 厚 1.2 / 高 3.5 + 垛口 0.55，原点在墙底中心、长度沿局部 X。
## 缺失时回退旧的 BoxMesh（保证 headless 与缺资产场景可跑）。
const WALL_SEGMENT_SCENE := "res://art/assets/models/wall/mdl_wall_segment_a_v2.glb"
const WALL_BREACH_SCENE := "res://art/assets/models/wall/mdl_wall_segment_breach_v2.glb"
const WALL_REINFORCED_SCENE := "res://art/assets/models/wall/mdl_wall_segment_reinforced_v2.glb"
const WALL_MESH_BOUNDS := AABB(Vector3(-3.575, 0.0, -0.80), Vector3(7.15, 4.075, 1.60))


static func _wall_yaw(center: Vector2, tangent: Vector2) -> float:
	# Blender exterior +Y imports as Godot -Z. Orient it away from the city,
	# even if the undirected gameplay tangent was constructed with the opposite sign.
	if Vector2(tangent.y, -tangent.x).dot(center) < 0.0:
		tangent = -tangent
	return atan2(-tangent.y, tangent.x)

func _add_wall_node(seg: Dictionary) -> void:
	var center: Vector2 = seg["center"]
	var tangent: Vector2 = seg["tangent"]
	var yaw := _wall_yaw(center, tangent)
	var gy := TerrainHeight.at(center.x, center.y)
	var pack: PackedScene = null
	if ResourceLoader.exists(WALL_SEGMENT_SCENE):
		pack = load(WALL_SEGMENT_SCENE) as PackedScene
	if pack != null:
		# GLB：容器挂在墙底，收集各 surface 的独立材质（受击变色 / 遮挡淡出按段生效）
		var inst := pack.instantiate() as Node3D
		add_child(inst)
		inst.position = Vector3(center.x, gy, center.y)
		inst.rotation.y = yaw
		inst.set_meta("index", int(seg["index"]))
		inst.set_meta("is_glb", true)
		var mats: Array = []
		for child in inst.find_children("*", "MeshInstance3D", true, false):
			var mi := child as MeshInstance3D
			if mi.mesh == null:
				continue
			for s in range(mi.mesh.get_surface_count()):
				var base := mi.get_active_material(s)
				if base == null:
					continue
				var dup := base.duplicate() as StandardMaterial3D
				if dup == null:
					continue
				dup.set_meta("base_albedo", dup.albedo_color)
				dup.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
				dup.albedo_color.a = 1.0
				mi.set_surface_override_material(s, dup)
				mats.append(dup)
		wall_nodes.append(inst)
		wall_materials.append(mats)
	else:
		# 兜底：旧方块
		var length := float(seg["half_len"]) * 2.0
		var box := BoxMesh.new()
		box.size = Vector3(length, wall_height, wall_thickness)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = WALL_COLOR
		mat.roughness = 0.85
		mat.set_meta("base_albedo", WALL_COLOR)
		box.material = mat
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.position = Vector3(center.x, wall_height * 0.5 + gy, center.y)
		mi.rotation.y = yaw
		mi.set_meta("index", int(seg["index"]))
		mi.set_meta("is_glb", false)
		add_child(mi)
		wall_nodes.append(mi)
		wall_materials.append([mat])



func _add_crystal(cfg: ConfigDB) -> void:
	if USE_CRYSTAL_MESH and _add_crystal_mesh():
		return
	# ---- 兜底：旧程序化锥台（GLB 缺失时仍能玩） ----
	var mesh := CylinderMesh.new()
	mesh.top_radius = 1.0
	mesh.bottom_radius = 1.6
	mesh.height = 4.2
	crystal_material = StandardMaterial3D.new()
	crystal_material.albedo_color = Color(0.35, 0.75, 0.95)
	crystal_material.emission_enabled = true
	crystal_material.emission = Color(0.25, 0.65, 0.95)
	crystal_material.emission_energy_multiplier = 1.6
	mesh.material = crystal_material
	crystal_node = MeshInstance3D.new()
	crystal_node.mesh = mesh
	crystal_node.position = Vector3(0, 2.1, 0)
	add_child(crystal_node)


## 实例化 Blender 资产：底座静止，菱形晶体单独做浮动/缩放/受击变色
func _add_crystal_mesh() -> bool:
	if not ResourceLoader.exists(CRYSTAL_SCENE):
		push_warning("[view] 水晶 GLB 缺失，回退程序化锥台：" + CRYSTAL_SCENE)
		return false
	var packed := load(CRYSTAL_SCENE) as PackedScene
	if packed == null:
		push_warning("[view] 水晶 GLB 无法加载，回退程序化锥台")
		return false
	var inst: Node3D = packed.instantiate()
	crystal_node = Node3D.new()
	crystal_node.name = "Crystal"
	crystal_node.add_child(inst)
	add_child(crystal_node)
	crystal_diamond = inst.find_child("GEO_Crystal_Diamond", true, false) as Node3D
	if crystal_diamond == null:
		push_warning("[view] 水晶 GLB 里找不到 GEO_Crystal_Diamond，整体做受击表现")
		crystal_diamond = inst
	# 只给晶体（不含石台阶）挂受击变色：进来时把材质复制一份，避免改到导入缓存
	crystal_effects.clear()
	var targets: Array = []
	if crystal_diamond is MeshInstance3D:
		targets.append(crystal_diamond)
	targets.append_array(crystal_diamond.find_children("*", "MeshInstance3D", true, false))
	for mi in targets:
		var mesh_inst: MeshInstance3D = mi
		if mesh_inst.mesh == null:
			continue
		for si in range(mesh_inst.mesh.get_surface_count()):
			var src := mesh_inst.get_active_material(si) as StandardMaterial3D
			if src == null:
				continue
			var dup: StandardMaterial3D = src.duplicate()
			mesh_inst.set_surface_override_material(si, dup)
			crystal_effects.append({
				"mat": dup,
				"base_albedo": dup.albedo_color,
				"base_emission": dup.emission,
			})
	return true


## 每帧同步墙体表现：破损隐藏、受击变红、血条由 HUD 负责
func sync_walls(snap: Dictionary) -> void:
	# 拆除自建墙段会让后续段索引前移：多出来的节点要先回收，否则会留下“幽灵墙”
	while wall_nodes.size() > snap["wall"].size():
		var stale: Node3D = wall_nodes.pop_back()
		stale.queue_free()
		wall_materials.pop_back()
	for seg in snap["wall"]:
		var idx := int(seg["index"])
		if idx >= wall_nodes.size():
			_add_wall_node(seg)      # 玩家新建的墙段：按需补节点（每波最多 1 段）
		if idx >= wall_nodes.size():
			continue
		var node: Node3D = wall_nodes[idx]
		var center: Vector2 = seg["center"]
		var tangent: Vector2 = seg["tangent"]
		var is_glb := bool(node.get_meta("is_glb", false))
		# 索引前移 / 几何变化（拆除后再建）都要把节点摆回正确位置
		if is_glb:
			node.position = Vector3(center.x, TerrainHeight.at(center.x, center.y), center.y)
		else:
			node.position = Vector3(center.x, wall_height * 0.5 + TerrainHeight.at(center.x, center.y), center.y)
			var box: BoxMesh = (node as MeshInstance3D).mesh
			if box != null:
				box.size = Vector3(float(seg["half_len"]) * 2.0, wall_height, wall_thickness)
		node.rotation.y = _wall_yaw(center, tangent)
		node.visible = not bool(seg["breached"])
		# 受击/低血：按段把所有 surface 从各自底色往伤色压；悬停再叠自发光
		var flash := clampf(float(seg["hit_flash"]) * 4.0, 0.0, 0.8)
		var hp_ratio := float(seg["hp"]) / maxf(1.0, float(seg["max_hp"]))
		var dmg := clampf(1.0 - hp_ratio, 0.0, 1.0)
		var hovered := idx == wall_hover and not bool(seg["breached"])
		for m in wall_materials[idx]:
			var mat := m as StandardMaterial3D
			if mat == null:
				continue
			var base: Color = mat.get_meta("base_albedo", WALL_COLOR)
			var tint := base.lerp(WALL_HURT, dmg * 0.62 + flash * 0.55)
			mat.albedo_color = Color(tint.r, tint.g, tint.b, mat.albedo_color.a)
			mat.emission_enabled = hovered
			if hovered:
				mat.emission = Color(0.95, 0.82, 0.45)
				mat.emission_energy_multiplier = 0.55


## 由 app 层每帧写入：建设期光标命中的墙段索引
func set_wall_hover(index: int) -> void:
	wall_hover = index


## Fade only walls between the camera and the player in 3D; no gameplay changes.
func update_occlusion(camera_pos: Vector3, player_pos: Vector2) -> void:
	var target := Vector3(player_pos.x, TerrainHeight.at(player_pos.x, player_pos.y) + 0.85, player_pos.y)
	var origin := camera_pos
	var camera := get_viewport().get_camera_3d()
	if camera != null and camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		# Orthographic rays are parallel, not aimed from the camera's center.
		origin = camera.project_ray_origin(camera.unproject_position(target))
	for i in range(wall_nodes.size()):
		var node := wall_nodes[i] as Node3D
		var blocked := false
		if node.visible and origin.distance_squared_to(target) > 0.01:
			var bounds := WALL_MESH_BOUNDS
			if node is MeshInstance3D and not bool(node.get_meta("is_glb", false)):
				bounds = (node as MeshInstance3D).get_aabb()
			blocked = bounds.intersects_segment(node.to_local(origin), node.to_local(target)) != null
		var mode := BaseMaterial3D.TRANSPARENCY_ALPHA if blocked else BaseMaterial3D.TRANSPARENCY_DISABLED
		for m in wall_materials[i]:
			var mat := m as StandardMaterial3D
			if mat.transparency != mode:
				mat.transparency = mode
				mat.albedo_color.a = 0.25 if blocked else 1.0


func sync_crystal(snap: Dictionary) -> void:
	if crystal_node == null:
		return
	var ratio := float(snap["crystal"]["hp"]) / maxf(1.0, float(snap["crystal"]["max_hp"]))
	var hurt := Color(0.95, 0.35, 0.30)
	# 有 GLB 资产：只染晶体（石台阶保持原色），并按血量做呼吸浮动
	if crystal_effects.size() > 0:
		var k := (1.0 - ratio) * 0.85
		for e in crystal_effects:
			var mat: StandardMaterial3D = e["mat"]
			# 用 lerp 保持明度（直接乘红色会把晶体压成黑红）
			mat.albedo_color = (e["base_albedo"] as Color).lerp(hurt, k)
			if mat.emission_enabled:
				mat.emission = (e["base_emission"] as Color).lerp(hurt, k)
				mat.emission_energy_multiplier = 0.9 + (1.0 - ratio) * 1.2
		if crystal_diamond != null:
			crystal_diamond.position.y = sin(Time.get_ticks_msec() * 0.001) * 0.10
			var pulse := 0.92 + 0.08 * ratio
			crystal_diamond.scale = Vector3(pulse, pulse, pulse)
		return
	# 兜底锥台：沿用旧表现
	if crystal_material == null:
		return
	crystal_material.albedo_color = hurt.lerp(Color(0.35, 0.75, 0.95), ratio)
	crystal_material.emission = crystal_material.albedo_color
	crystal_node.scale = Vector3.ONE * (0.85 + 0.15 * ratio)
	crystal_node.position.y = 2.1 + sin(Time.get_ticks_msec() * 0.001) * 0.12
