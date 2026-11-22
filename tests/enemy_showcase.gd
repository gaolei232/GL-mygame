extends SceneTree
## 敌人 GLB 展示/验收：4 种低模并排、检查尺寸与脚底贴地 + 截图。
## 用法：godot --path . --script res://tests/enemy_showcase.gd

var kinds := ["walker", "runner", "bomber", "brute"]
var xs := [-4.2, -1.4, 1.4, 4.4]


func _initialize() -> void:
	_run()


func _world_aabb(node: Node) -> AABB:
	var out := AABB()
	var first := true
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		if m.mesh == null:
			continue
		var box: AABB = m.global_transform * m.mesh.get_aabb()
		if first:
			out = box
			first = false
		else:
			out = out.merge(box)
	return out


func _run() -> void:
	await process_frame
	var root3d := Node3D.new()
	root.add_child(root3d)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.08, 0.09, 0.11)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.45, 0.5, 0.58)
	e.ambient_light_energy = 0.8
	env.environment = e
	root3d.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	root3d.add_child(sun)

	var plane := PlaneMesh.new()
	plane.size = Vector2(24, 24)
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.16, 0.17, 0.19)
	pm.roughness = 0.95
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	ground.material_override = pm
	root3d.add_child(ground)

	var cam := Camera3D.new()
	cam.fov = 42.0
	root3d.add_child(cam)
	cam.look_at_from_position(Vector3(0, 3.1, -14.0), Vector3(0, 1.35, 0), Vector3.UP)
	cam.current = true

	for i in kinds.size():
		var kind: String = kinds[i]
		var path := "res://art/assets/models/mon/mdl_mon_%s_normal_v2.glb" % kind
		if not ResourceLoader.exists(path):
			print("MISSING ", kind)
			continue
		var inst: Node3D = (load(path) as PackedScene).instantiate()
		inst.position = Vector3(xs[i], 0, 0)
		root3d.add_child(inst)
		await process_frame
		var aabb := _world_aabb(inst)
		var ap := inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
		var anims: Array = []
		if ap != null:
			for a in ap.get_animation_list():
				anims.append(a)
			# 展示动作用走姿而非 T 姿势（四种各取不同相位）
			ap.play("walk")
			ap.seek([0.15, 0.42, 0.66, 0.30][i], true)
		print("SHOWCASE %s height=%.2f foot=%.2f anims=%s" %
			[kind, aabb.size.y, aabb.position.y, str(anims)])

	for i in range(6):
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png("res://shots/_enemy_showcase.png")
	print("shot _enemy_showcase.png ", img.get_size())
	quit(0)