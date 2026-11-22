class_name BuildLayer
extends Node3D
## 表现层 · 建造物：木箱 / 炮台 / 掉落物 / 放置预览。
## 只读 snapshot；不写逻辑。城墙段仍由 WorldBuilder 负责。

const CRATE_COLOR := Color(0.62, 0.45, 0.26)
const CRATE_STRAP := Color(0.40, 0.28, 0.16)
const CANNON_BASE := Color(0.36, 0.38, 0.42)
const CANNON_TURRET := Color(0.54, 0.57, 0.62)
const HURT := Color(0.90, 0.32, 0.25)
const GHOST_OK := Color(0.35, 0.92, 0.52, 0.38)
const GHOST_BAD := Color(0.95, 0.32, 0.25, 0.38)
const TIER_COLORS := [
	Color(0.81, 0.83, 0.86), Color(0.50, 0.79, 0.54), Color(0.42, 0.68, 0.94), Color(0.88, 0.70, 0.30),
]

var _roots: Dictionary = {}         # building id -> Node3D
var _body_mats: Dictionary = {}     # building id -> StandardMaterial3D
var _base_colors: Dictionary = {}   # building id -> Color
var _turrets: Dictionary = {}       # building id -> Node3D
var _drop_views: Dictionary = {}    # drop id -> MeshInstance3D
var _ghost: MeshInstance3D
var _ghost_box: BoxMesh
var _ghost_mat: StandardMaterial3D
var _hover_id := -1


func _ready() -> void:
	_ghost_box = BoxMesh.new()
	_ghost_box.size = Vector3.ONE
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.albedo_color = GHOST_OK
	_ghost_box.material = _ghost_mat
	_ghost = MeshInstance3D.new()
	_ghost.mesh = _ghost_box
	_ghost.visible = false
	add_child(_ghost)


func reset() -> void:
	for id in _roots.keys():
		(_roots[id] as Node3D).queue_free()
	_roots.clear()
	_body_mats.clear()
	_base_colors.clear()
	_turrets.clear()
	for id in _drop_views.keys():
		(_drop_views[id] as MeshInstance3D).queue_free()
	_drop_views.clear()
	_ghost.visible = false
	_hover_id = -1


func sync(snap: Dictionary, delta: float) -> void:
	_sync_buildings(snap, delta)
	_sync_drops(snap)


func _sync_buildings(snap: Dictionary, delta: float) -> void:
	var seen := {}
	for b in snap.get("buildings", []):
		var id := int(b.get("id", 0))
		seen[id] = true
		var root: Node3D = _roots.get(id)
		if root == null:
			if str(b.get("kind", "")) == "crate":
				root = _make_crate()
			else:
				root = _make_cannon()
			add_child(root)
			_roots[id] = root
			_body_mats[id] = root.get_meta("body_mat")
			_base_colors[id] = root.get_meta("base_color")
			if root.has_meta("turret"):
				_turrets[id] = root.get_meta("turret")
		var pos: Vector2 = b.get("pos", Vector2.ZERO)
		root.position = Vector3(pos.x, 0.0, pos.y)
		var ratio := float(b.get("hp", 1.0)) / maxf(1.0, float(b.get("max_hp", 1.0)))
		var base: Color = _base_colors.get(id, Color.WHITE)
		var mat: StandardMaterial3D = _body_mats.get(id)
		if mat != null:
			var color: Color = base.lerp(HURT, clampf(1.0 - ratio, 0.0, 1.0) * 0.7)
			if float(b.get("hit_flash", 0.0)) > 0.0:
				color = color.lerp(Color.WHITE, 0.75)
			if id == _hover_id:
				mat.emission_enabled = true
				mat.emission = Color(0.95, 0.35, 0.30)
				mat.emission_energy_multiplier = 0.6
			else:
				mat.emission_enabled = false
			mat.albedo_color = color
		# 炮台炮塔转向最近敌人（纯表现，不影响命中）
		var turret: Node3D = _turrets.get(id)
		if turret != null:
			var target: Vector2 = Vector2.ZERO
			var best := 18.0
			for e in snap.get("enemies", []):
				var d: float = pos.distance_to(e.get("pos", Vector2.ZERO))
				if d < best:
					best = d
					target = e.get("pos", Vector2.ZERO)
			if best < 18.0:
				var dir := target - pos
				if dir.length() > 0.1:
					var want := atan2(dir.x, dir.y)
					turret.rotation.y = lerp_angle(turret.rotation.y, want, clampf(delta * 6.0, 0.0, 1.0))
	for id in _roots.keys():
		if not seen.has(id):
			(_roots[id] as Node3D).queue_free()
			_roots.erase(id)
			_body_mats.erase(id)
			_base_colors.erase(id)
			_turrets.erase(id)


func _sync_drops(snap: Dictionary) -> void:
	var seen := {}
	for d in snap.get("drops", []):
		var id := int(d.get("id", 0))
		seen[id] = true
		var view: MeshInstance3D = _drop_views.get(id)
		if view == null:
			var mesh := SphereMesh.new()
			mesh.radius = 0.16
			mesh.height = 0.32
			var mat := StandardMaterial3D.new()
			mat.albedo_color = _drop_color(str(d.get("kind", "coin")))
			mat.emission_enabled = true
			mat.emission = mat.albedo_color
			mat.emission_energy_multiplier = 0.35
			mesh.material = mat
			view = MeshInstance3D.new()
			view.mesh = mesh
			add_child(view)
			_drop_views[id] = view
		var pos: Vector2 = d.get("pos", Vector2.ZERO)
		var bob := sin(Time.get_ticks_msec() * 0.004 + float(id)) * 0.06
		view.position = Vector3(pos.x, 0.24 + bob, pos.y)
		var ttl := float(d.get("ttl", 60.0))
		# 最后 5s 闪烁提示即将消失
		view.visible = ttl > 5.0 or fmod(Time.get_ticks_msec() * 0.006, 1.0) > 0.35
	for id in _drop_views.keys():
		if not seen.has(id):
			(_drop_views[id] as MeshInstance3D).queue_free()
			_drop_views.erase(id)


func _drop_color(kind: String) -> Color:
	match kind:
		"coin": return Color(0.95, 0.80, 0.42)
		"brick": return Color(0.78, 0.62, 0.44)
		"metal": return Color(0.72, 0.78, 0.86)
		"ammo": return Color(0.95, 0.72, 0.50)
		"item": return Color(0.88, 0.70, 0.30)
	return Color.WHITE


func _make_crate() -> Node3D:
	var root := Node3D.new()
	var body := BoxMesh.new()
	body.size = Vector3(1.2, 1.2, 1.2)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = CRATE_COLOR
	mat.roughness = 0.85
	body.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = body
	mi.position.y = 0.6
	root.add_child(mi)
	# 两道深色箍：远看也能和"可搜索的物资箱"区分开
	for x in [-0.42, 0.42]:
		var strap := BoxMesh.new()
		strap.size = Vector3(0.12, 1.24, 1.24)
		var smat := StandardMaterial3D.new()
		smat.albedo_color = CRATE_STRAP
		strap.material = smat
		var s := MeshInstance3D.new()
		s.mesh = strap
		s.position = Vector3(x, 0.6, 0)
		root.add_child(s)
	root.set_meta("body_mat", mat)
	root.set_meta("base_color", CRATE_COLOR)
	return root


func _make_cannon() -> Node3D:
	var root := Node3D.new()
	var base := BoxMesh.new()
	base.size = Vector3(2.0, 0.5, 2.0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = CANNON_BASE
	bmat.roughness = 0.75
	base.material = bmat
	var bmi := MeshInstance3D.new()
	bmi.mesh = base
	bmi.position.y = 0.25
	root.add_child(bmi)
	var turret := Node3D.new()
	turret.position.y = 0.85
	root.add_child(turret)
	var head := CylinderMesh.new()
	head.top_radius = 0.52
	head.bottom_radius = 0.62
	head.height = 0.7
	var hmat := StandardMaterial3D.new()
	hmat.albedo_color = CANNON_TURRET
	hmat.roughness = 0.6
	head.material = hmat
	var hmi := MeshInstance3D.new()
	hmi.mesh = head
	turret.add_child(hmi)
	var barrel := BoxMesh.new()
	barrel.size = Vector3(0.20, 0.20, 1.5)
	var bar_mat := StandardMaterial3D.new()
	bar_mat.albedo_color = CANNON_TURRET.darkened(0.2)
	barrel.material = bar_mat
	var bari := MeshInstance3D.new()
	bari.mesh = barrel
	bari.position = Vector3(0, 0.1, 0.75)
	turret.add_child(bari)
	# 注册在 sync 里按 building id 做；这里只把 turret 交给 root 的元数据
	root.set_meta("turret", turret)
	root.set_meta("body_mat", bmat)
	root.set_meta("base_color", CANNON_BASE)
	return root


func set_ghost(id: String, pos: Vector2, valid: bool) -> void:
	if id == "" or id == "backpack":
		_ghost.visible = false
		return
	_ghost.visible = true
	_ghost.position = Vector3(pos.x, 0.0, pos.y)
	var size := Vector3(1.2, 1.2, 1.2)
	var y := 0.6
	var yaw := 0.0
	match id:
		"crate":
			size = Vector3(1.2, 1.2, 1.2)
		"cannon":
			size = Vector3(2.0, 1.8, 2.0)
			y = 0.9
		"wall":
			size = Vector3(6.9, 3.5, 1.2)
			y = 1.75
			yaw = atan2(-pos.normalized().orthogonal().y, pos.normalized().orthogonal().x)
		_:
			pass
	_ghost_box.size = size
	_ghost.position.y = y
	_ghost.rotation.y = yaw
	_ghost_mat.albedo_color = GHOST_OK if valid else GHOST_BAD


func set_hover(building_id: int) -> void:
	_hover_id = building_id