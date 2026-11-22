extends SceneTree
## 树木组件验收：导入三档 GLB + 组件包，按游戏相机比例出图，并放一个 1.8m 参照物比尺度。
## 用法：godot --path . --script res://tests/tree_showcase.gd

const TIERS := {"small": 3.84, "medium": 5.67, "large": 7.95}
const PATHS := {
	"small": "res://art/assets/models/tree/mdl_tree_small_a_v1.glb",
	"medium": "res://art/assets/models/tree/mdl_tree_medium_a_v1.glb",
	"large": "res://art/assets/models/tree/mdl_tree_large_a_v1.glb",
	"medium_b": "res://art/assets/models/tree/mdl_tree_medium_b_v1.glb",
	"kit": "res://art/assets/models/tree/mdl_tree_kit_a_v1.glb",
}

var root3d: Node3D
var cam: Camera3D
var placed: Array = []


func _initialize() -> void:
	_run()


func _setup() -> void:
	root3d = Node3D.new()
	root.add_child(root3d)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.10, 0.12, 0.14)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.52, 0.56, 0.62)
	env.environment.ambient_light_energy = 0.85
	root3d.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -35, 0)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	root3d.add_child(sun)
	# 地面用游戏荒地色，方便判断"落不落地"
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.247, 0.239, 0.208)
	mat.roughness = 0.95
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	ground.material_override = mat
	root3d.add_child(ground)
	cam = Camera3D.new()
	cam.fov = 45.0
	cam.near = 0.05
	cam.far = 200.0
	root3d.add_child(cam)
	cam.make_current()


func _place(kind: String, pos: Vector3, rot_y: float = 0.0, scale: float = 1.0) -> Node3D:
	var path: String = PATHS[kind]
	if not ResourceLoader.exists(path):
		push_error("missing " + path)
		return null
	var inst: Node3D = (load(path) as PackedScene).instantiate()
	inst.position = pos
	inst.rotation.y = rot_y
	inst.scale = Vector3.ONE * scale
	root3d.add_child(inst)
	placed.append(inst)
	return inst


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png("res://shots/_tree_%s.png" % name)
	print("shot _tree_%s.png %s" % [name, str(img.get_size())])


func _run() -> void:
	await process_frame
	_setup()
	await process_frame

	# 三档并排 + 1.8m 参照柱（与玩家同高，用来判断树有多大）
	_place("small", Vector3(-4.2, 0, 0))
	_place("medium", Vector3(0, 0, 0), 0.6)
	_place("large", Vector3(4.6, 0, 0), -0.4)
	var ref := MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.42
	cap.height = 1.8
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(0.35, 0.62, 0.95)
	cap.material = cap_mat
	ref.mesh = cap
	ref.position = Vector3(2.2, 0.9, 1.8)
	root3d.add_child(ref)

	# 游戏同参数：正交 26m / 俯角 52° / yaw45
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 26.0
	cam.look_at_from_position(Vector3(30.0, 46.0, -30.0), Vector3(0, 1.2, 0), Vector3.UP)
	await _shot("lineup_game")

	# 近景 3/4：看树干/分叉/叶团的细节
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = 42.0
	cam.look_at_from_position(Vector3(-7.0, 6.5, 12.0), Vector3(0.4, 2.6, 0), Vector3.UP)
	await _shot("lineup_close")

	# 复用演示：同一批零件派生的 b 变体 + 小树成丛（做"树丛"场景）
	for inst in placed:
		inst.queue_free()
	placed.clear()
	await process_frame
	_place("medium_b", Vector3(-3.0, 0, 4.0), 1.2)
	_place("medium", Vector3(0.2, 0, 4.6), -0.9, 0.92)
	_place("small", Vector3(3.0, 0, 4.2), 2.0)
	_place("small", Vector3(4.4, 0, 5.4), 0.4, 0.85)
	_place("medium_b", Vector3(6.2, 0, 3.6), -1.6, 0.88)
	cam.look_at_from_position(Vector3(-8.0, 5.0, 13.5), Vector3(0.8, 2.4, 4.6), Vector3.UP)
	await _shot("cluster")

	# 组件包：确认 11 个零件都在、命名可枚举
	var kit := _place("kit", Vector3(0, 0, -14))
	if kit != null:
		var names: Array = []
		for mi in kit.find_children("*", "MeshInstance3D", true, false):
			names.append(String(mi.name))
		names.sort()
		print("KIT_PARTS ", names.size(), " ", names)
	quit(0)