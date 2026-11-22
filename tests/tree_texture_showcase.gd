extends SceneTree
## 用户贴图四件的实机/引擎验收：贴图树、草地泥土地面、灌木贴图球。
## 用法：godot --path . --script res://tests/tree_texture_showcase.gd

const TEX := {
	"bark": "res://art/assets/tex/tex_tree_bark_v1.png",
	"leaf": "res://art/assets/tex/tex_tree_leaf_v1.png",
	"bush": "res://art/assets/tex/tex_tree_bush_v1.png",
	"ground": "res://art/assets/tex/tex_ground_grassdirt_v1.png",
}

var root3d: Node3D
var cam: Camera3D


func _initialize() -> void:
	_run()


func _setup() -> void:
	root3d = Node3D.new()
	root.add_child(root3d)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.12, 0.14, 0.16)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.58, 0.62)
	env.environment.ambient_light_energy = 0.9
	root3d.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -32, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	root3d.add_child(sun)

	# 草地泥土地面：用户贴图乘色压暗到游戏荒地的亮度
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_texture = load(TEX["ground"])
	ground_mat.albedo_color = Color(0.42, 0.38, 0.30)
	ground_mat.roughness = 0.95
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	ground.material_override = ground_mat
	root3d.add_child(ground)

	cam = Camera3D.new()
	cam.fov = 45.0
	cam.near = 0.05
	cam.far = 200.0
	root3d.add_child(cam)
	cam.make_current()


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png("res://shots/_tree_tex_%s.png" % name)
	print("shot _tree_tex_%s.png %s" % [name, str(img.get_size())])


func _run() -> void:
	await process_frame
	_setup()
	await process_frame

	# 1) 贴图树（树皮 + 绿叶），与枯树变体并排对照
	var tex_tree: Node3D = (load("res://art/assets/models/tree/mdl_tree_medium_a_tex_v1.glb") as PackedScene).instantiate()
	tex_tree.position = Vector3(-3.2, 0, 0)
	root3d.add_child(tex_tree)
	var dry_tree: Node3D = (load("res://art/assets/models/tree/mdl_tree_medium_a_v1.glb") as PackedScene).instantiate()
	dry_tree.position = Vector3(3.2, 0, 0)
	root3d.add_child(dry_tree)

	# 2) 灌木贴图球：看 tex_tree_bush 贴在体积上是否能读作灌木（只作球体参考）
	var bush_mat := StandardMaterial3D.new()
	bush_mat.albedo_texture = load(TEX["bush"])
	bush_mat.albedo_color = Color(0.36, 0.50, 0.30)
	bush_mat.roughness = 0.95
	var bush := MeshInstance3D.new()
	bush.mesh = SphereMesh.new()
	bush.mesh.radius = 1.0
	bush.mesh.height = 1.3
	bush.material_override = bush_mat
	bush.position = Vector3(0, 0.75, 5.5)
	root3d.add_child(bush)

	cam.look_at_from_position(Vector3(-7.5, 5.5, 13.0), Vector3(0, 2.2, 1.2), Vector3.UP)
	await _shot("compare")

	# 3) 游戏相机：贴图树的实际游戏尺度观感
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 26.0
	cam.look_at_from_position(Vector3(28.0, 42.0, -28.0), Vector3(0, 1.6, 0), Vector3.UP)
	await _shot("game")
	quit(0)