extends SceneTree
## 敌人动作姿态验收：干净场景里 4 种低模各摆 walk / attack / fuse 姿态并单独截图。
## 用法：godot --path . --script res://tests/enemy_pose_sheet.gd

const KINDS := ["walker", "runner", "bomber", "brute"]
const HEIGHTS := {"walker": 1.8, "runner": 1.7, "bomber": 1.8, "brute": 3.2}
const ATTACK_AT := {"walker": 0.40, "runner": 0.34, "bomber": 0.40, "brute": 0.58}

var root3d: Node3D
var cam: Camera3D


func _initialize() -> void:
	_run()


func _setup() -> void:
	root3d = Node3D.new()
	root.add_child(root3d)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.07, 0.08, 0.10)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.48, 0.53, 0.60)
	e.ambient_light_energy = 0.9
	env.environment = e
	root3d.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -35, 0)
	sun.light_energy = 1.6
	sun.shadow_enabled = true
	root3d.add_child(sun)

	var plane := PlaneMesh.new()
	plane.size = Vector2(30, 30)
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.16, 0.17, 0.19)
	pm.roughness = 0.95
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	ground.material_override = pm
	root3d.add_child(ground)

	cam = Camera3D.new()
	cam.fov = 40.0
	cam.near = 0.05
	cam.far = 100.0
	root3d.add_child(cam)
	cam.current = true


func _load(kind: String) -> Node3D:
	var path := "res://art/assets/models/mon/mdl_mon_%s_normal_v2.glb" % kind
	if not ResourceLoader.exists(path):
		print("MISSING ", kind)
		return null
	var inst: Node3D = (load(path) as PackedScene).instantiate()
	root3d.add_child(inst)
	return inst


func _pose(inst: Node3D, anim: String, sec: float) -> void:
	var ap := inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap == null:
		print("NO ANIM ", inst.name)
		return
	if not ap.has_animation(anim):
		print("NO ANIM ", anim)
		return
	ap.play(anim)
	ap.seek(sec, true)
	ap.pause()


func _cam_for(kind: String, pos: Vector3) -> void:
	var h: float = HEIGHTS[kind]
	# 取景高度要算上抬手/跃起：brute 挥拳时手会高出头顶 1m+
	var fh: float = h + (1.3 if kind == "brute" else 0.45)
	cam.global_position = pos + Vector3(-fh * 0.85, fh * 0.95, -fh * 1.8)
	cam.look_at(pos + Vector3(0, h * 0.50, 0), Vector3.UP)


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png("res://shots/_enemy_pose_%s.png" % name)
	print("shot _enemy_pose_%s.png %s" % [name, str(img.get_size())])


func _run() -> void:
	await process_frame
	_setup()
	await process_frame

	for kind in KINDS:
		var inst := _load(kind)
		if inst == null:
			continue
		var pos := Vector3.ZERO
		_cam_for(kind, pos)
		await process_frame
		_pose(inst, "walk", 0.45)
		await process_frame
		await _shot("%s_walk" % kind)
		_pose(inst, "attack", float(ATTACK_AT[kind]))
		await process_frame
		await _shot("%s_attack" % kind)
		if kind == "bomber":
			_pose(inst, "fuse", 1.0)
			await process_frame
			await _shot("bomber_fuse")
		inst.queue_free()
		await process_frame

	# 并排合影：4 种各取攻击动作（bomber 取 fuse），从正面 3/4 看
	var xs := [-3.9, -1.3, 1.3, 4.3]
	for i in KINDS.size():
		var inst2 := _load(KINDS[i])
		if inst2 == null:
			continue
		inst2.position = Vector3(xs[i], 0, 0)
		await process_frame
		if KINDS[i] == "bomber":
			_pose(inst2, "fuse", 1.0)
		else:
			_pose(inst2, "attack", float(ATTACK_AT[KINDS[i]]))
		await process_frame
	cam.fov = 42.0
	cam.global_position = Vector3(-1.2, 4.6, -11.5)
	cam.look_at(Vector3(0.2, 1.35, 0), Vector3.UP)
	cam.current = true
	await process_frame
	await _shot("lineup_attack")

	print("POSE_SHEET_DONE")
	quit(0)