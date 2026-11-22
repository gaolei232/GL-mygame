extends SceneTree
## 宝箱开盖动画验收：三档箱子，合盖 / 半开 / 全开 三阶段截图 + 枢轴位置检查。
## 用法：godot --path . --script res://tests/loot_box_open_anim.gd

const TIERS := ["wood", "metal", "military"]
const SCENES := {
	"wood": "res://art/assets/models/prop/mdl_loot_box_wood_v4.glb",
	"metal": "res://art/assets/models/prop/mdl_loot_box_metal_v4.glb",
	"military": "res://art/assets/models/prop/mdl_loot_box_military_v4.glb",
}
const LID_PIVOT_POS := Vector3(0, 0.64, 0.39)
const LID_OPEN_RAD := 1.92

var fails := 0
var checks := 0


func _ok(cond: bool, label: String, detail: String = "") -> void:
	checks += 1
	if cond:
		print("OK   ", label, (" | " + detail) if detail != "" else "")
	else:
		fails += 1
		print("FAIL ", label, (" | " + detail) if detail != "" else "")


func _initialize() -> void:
	_run()


## 与 view/unit_layer.gd._make_loot_box_view 相同的盖子拆分逻辑
func _make_view(tier: String) -> Node3D:
	var container := Node3D.new()
	var inst: Node3D = (load(SCENES[tier]) as PackedScene).instantiate()
	container.add_child(inst)
	var lid_meshes: Array = []
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		if (mi as Node).name.begins_with("GEO_Chest_Lid"):
			lid_meshes.append(mi)
	var pivot := Node3D.new()
	pivot.name = "LidPivot"
	pivot.position = LID_PIVOT_POS
	container.add_child(pivot)
	for mi in lid_meshes:
		var lm := mi as Node3D
		var pos := lm.position - LID_PIVOT_POS
		lm.get_parent().remove_child(lm)
		lm.owner = null
		pivot.add_child(lm)
		lm.position = pos
	container.set_meta("lid_pivot", pivot)
	container.set_meta("lid_count", lid_meshes.size())
	return container


func _lid_aabb(view: Node3D) -> AABB:
	var pivot: Node3D = view.get_meta("lid_pivot")
	var out := AABB()
	var first := true
	for mi in pivot.get_children():
		var m := mi as MeshInstance3D
		if m == null or m.mesh == null:
			continue
		var b: AABB = m.global_transform * m.mesh.get_aabb()
		if first:
			out = b
			first = false
		else:
			out = out.merge(b)
	return out


func _run() -> void:
	await process_frame
	var root3d := Node3D.new()
	root.add_child(root3d)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.13)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.52, 0.55, 0.60)
	e.ambient_light_energy = 1.0
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
	pm.albedo_color = Color(0.17, 0.18, 0.20)
	pm.roughness = 0.95
	var ground := MeshInstance3D.new()
	ground.mesh = plane
	ground.material_override = pm
	root3d.add_child(ground)

	var cam := Camera3D.new()
	cam.fov = 40.0
	root3d.add_child(cam)
	cam.look_at_from_position(Vector3(0, 2.2, -4.8), Vector3(0, 0.55, 0), Vector3.UP)
	cam.current = true

	var xs := [-1.35, 0.0, 1.35]
	var views: Array = []
	for i in TIERS.size():
		var tier: String = TIERS[i]
		var view := _make_view(tier)
		view.position = Vector3(xs[i], 0, 0)
		view.rotation.y = [0.35, -0.2, 0.6][i]
		root3d.add_child(view)
		views.append(view)
	await process_frame

	for v in views:
		var tier2: String = TIERS[views.find(v)]
		_ok(int(v.get_meta("lid_count")) >= 1, "%s 盖子网格已拆出" % tier2,
			"count=%d" % int(v.get_meta("lid_count")))
		var closed := _lid_aabb(v)
		_ok(closed.position.y > 0.60, "%s 盖子初始在箱体上方" % tier2,
			"lid_y=%.3f" % closed.position.y)

	# 三阶段：合盖 / 半开 / 全开
	var stages := [[0.0, "closed"], [0.5, "half"], [1.0, "open"]]
	for stage in stages:
		var t: float = stage[0]
		var label: String = stage[1]
		for v in views:
			var pivot: Node3D = v.get_meta("lid_pivot")
			pivot.rotation.x = t * LID_OPEN_RAD
		await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.save_png("res://shots/_loot_box_lid_%s.png" % label)
		print("shot _loot_box_lid_%s.png %s" % [label, str(img.get_size())])

	# 全开时盖子应整体翻到箱口后上方（世界 AABB 最小 z 明显后移）
	for i in views.size():
		var v2: Node3D = views[i]
		var pivot2: Node3D = v2.get_meta("lid_pivot")
		pivot2.rotation.x = 0.0
		await process_frame
		var closed_box := _lid_aabb(v2)
		pivot2.rotation.x = LID_OPEN_RAD
		await process_frame
		var open_box := _lid_aabb(v2)
		_ok(open_box.position.z > closed_box.position.z + 0.30,
			"%s 开盖后盖子翻到箱口后方" % TIERS[i],
			"closed_z=%.2f open_z=%.2f" % [closed_box.position.z, open_box.position.z])

	print("LOOT_BOX_OPEN_ANIM checks=%d fails=%d" % [checks, fails])
	quit(0 if fails == 0 else 1)