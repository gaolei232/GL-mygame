extends SceneTree
## 宝箱 GLB 验收（Godot 侧）：三档模型并排 + 尺寸/脚底/材质 + 截图。
## 用法：godot --path . --script res://tests/loot_box_showcase.gd

const TIERS := ["wood", "metal", "military"]
const SCENES := {
	"wood": "res://art/assets/models/prop/mdl_loot_box_wood_v4.glb",
	"metal": "res://art/assets/models/prop/mdl_loot_box_metal_v4.glb",
	"military": "res://art/assets/models/prop/mdl_loot_box_military_v4.glb",
}
const EXPECT_TRIS := {"wood": 620, "metal": 608, "military": 608}
const EXPECT_MATS := 6

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


func _world_aabb(node: Node) -> AABB:
	var out := AABB()
	var first := true
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		if m.mesh == null:
			continue
		var b: AABB = m.global_transform * m.mesh.get_aabb()
		if first:
			out = b
			first = false
		else:
			out = out.merge(b)
	return out


func _tri_count(node: Node) -> int:
	var n := 0
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		if m.mesh == null:
			continue
		for s in m.mesh.get_surface_count():
			var arrays: Array = m.mesh.surface_get_arrays(s)
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if idx.size() > 0:
				n += idx.size() / 3
			else:
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				n += verts.size() / 3
	return n


func _mat_names(node: Node) -> Array:
	var out: Array = []
	for mi in node.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		if m.mesh == null:
			continue
		for s in m.mesh.get_surface_count():
			var mat := m.mesh.surface_get_material(s)
			if mat != null and not out.has(mat.resource_name):
				out.append(mat.resource_name)
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
	e.ambient_light_color = Color(0.50, 0.53, 0.58)
	e.ambient_light_energy = 0.9
	env.environment = e
	root3d.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -34, 0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	root3d.add_child(sun)

	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
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
	cam.look_at_from_position(Vector3(0, 2.0, -4.6), Vector3(0, 0.45, 0), Vector3.UP)
	cam.current = true

	var xs := [-1.35, 0.0, 1.35]
	for i in TIERS.size():
		var tier: String = TIERS[i]
		var path: String = SCENES[tier]
		_ok(ResourceLoader.exists(path), "%s GLB 存在" % tier)
		if not ResourceLoader.exists(path):
			continue
		var inst: Node3D = (load(path) as PackedScene).instantiate()
		inst.position = Vector3(xs[i], 0, 0)
		inst.rotation.y = [0.35, -0.2, 0.6][i]
		root3d.add_child(inst)
		await process_frame
		var aabb := _world_aabb(inst)
		var tris := _tri_count(inst)
		var mats := _mat_names(inst)
		print("BOX %s height=%.2f foot=%.3f width=%.2f tris=%d mats=%s" %
			[tier, aabb.size.y, aabb.position.y, aabb.size.x, tris, str(mats)])
		_ok(absf(aabb.size.y - 0.82) < 0.14, "%s 高度≈0.82m" % tier, "%.3f" % aabb.size.y)
		_ok(absf(aabb.position.y) < 0.03, "%s 脚底贴地" % tier, "%.3f" % aabb.position.y)
		_ok(tris == int(EXPECT_TRIS[tier]), "%s tris=%d" % [tier, EXPECT_TRIS[tier]],
			"got=%d" % tris)
		_ok(mats.size() <= EXPECT_MATS, "%s 材质 ≤6" % tier, "got=%d" % mats.size())
		# 开盖动画前提：盖子网格独立（GEO_Chest_Lid*）
		var lid_n := 0
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			if (mi as Node).name.begins_with("GEO_Chest_Lid"):
				lid_n += 1
		_ok(lid_n >= 1, "%s 有独立盖子网格" % tier, "lid_meshes=%d" % lid_n)

	for i in range(6):
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png("res://shots/_loot_box_showcase.png")
	print("shot _loot_box_showcase.png ", img.get_size())
	print("LOOT_BOX_SHOWCASE checks=%d fails=%d" % [checks, fails])
	quit(0 if fails == 0 else 1)