extends SceneTree
## Run headless for assertions, or with a renderer and -- --capture for PNG evidence.

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	if not ok:
		failures += 1
		printerr("FAIL ", description)


func _material_mode(world: WorldBuilder, idx: int, faded: bool) -> bool:
	var materials: Array = world.wall_materials[idx]
	if materials.is_empty():
		return false
	var mode := BaseMaterial3D.TRANSPARENCY_ALPHA if faded else BaseMaterial3D.TRANSPARENCY_DISABLED
	var alpha := 0.25 if faded else 1.0
	for mat in materials:
		if mat.transparency != mode or not is_equal_approx(mat.albedo_color.a, alpha):
			return false
	return true


func _run() -> void:
	var cfg := ConfigDB.new()
	if not cfg.load_all():
		printerr(cfg.errors)
		quit(1)
		return
	var sim := Sim.new(cfg)
	sim.new_run(123)
	var snap := sim.snapshot()
	var world := WorldBuilder.new()
	root.add_child(world)
	var custom: Dictionary = snap["wall"][3].duplicate()
	var initial_count: int = snap["wall"].size()
	custom["index"] = initial_count
	custom["center"] = Vector2(5, -10)
	custom["tangent"] = -Vector2(custom["center"]).normalized().orthogonal()
	# Supply whichever tangent sign sends asset -Z inward, as a saved/custom wall can.
	var custom_tangent: Vector2 = custom["tangent"]
	if Vector2(custom_tangent.y, -custom_tangent.x).dot(custom["center"]) > 0:
		custom["tangent"] = -custom_tangent
	snap["wall"].append(custom)
	world.build(cfg, snap)
	for i in range(world.wall_nodes.size()):
		var node := world.wall_nodes[i] as Node3D
		var seg: Dictionary = snap["wall"][i]
		var center: Vector2 = seg["center"]
		var tangent: Vector2 = seg["tangent"]
		_check(node.scene_file_path == WorldBuilder.WALL_SEGMENT_SCENE, "runtime v2 GLB, wall %d" % i)
		_check(_material_mode(world, i, false), "initial opaque material, wall %d" % i)
		var outward := -node.global_basis.z
		_check(Vector2(outward.x, outward.z).dot(center.normalized()) > 0.99, "outward asset face, wall %d" % i)
		var axis := node.global_basis.x
		_check(absf(Vector2(axis.x, axis.z).dot(tangent)) > 0.99, "tangent footprint, wall %d" % i)

	var idx := initial_count / 2
	var point := Vector2(snap["wall"][idx]["center"])
	var near_camera := Vector3(point.x, 4.7, point.y - 4)
	var player := point + Vector2(0, 1.4)
	world.update_occlusion(near_camera, player)
	_check(_material_mode(world, idx, true), "intersecting view fades wall")
	_check(_material_mode(world, idx - 1, false), "untouched neighbor remains opaque")
	snap["wall"][idx]["hit_flash"] = 0.2
	world.set_wall_hover(idx)
	world.sync_walls(snap)
	var damaged_mat: StandardMaterial3D = world.wall_materials[idx][0]
	_check(damaged_mat.emission_enabled and not damaged_mat.albedo_color.is_equal_approx(damaged_mat.get_meta("base_albedo")), "hover and damage coexist with fade")
	world.update_occlusion(Vector3(point.x, 40, point.y - 4), player)
	_check(_material_mode(world, idx, false), "overhead view restores opaque pass")
	_check(damaged_mat.emission_enabled and damaged_mat.albedo_color.r != damaged_mat.get_meta("base_albedo").r, "restoring opacity preserves damage/hover")
	snap["wall"][idx]["breached"] = true
	world.sync_walls(snap)
	world.update_occlusion(near_camera, player)
	_check(not world.wall_nodes[idx].visible and _material_mode(world, idx, false), "breached segment stays hidden and opaque")
	snap["wall"][idx]["breached"] = false
	snap["wall"][idx]["hit_flash"] = 0.0
	snap["wall"].pop_back()
	world.set_wall_hover(-1)
	world.sync_walls(snap)
	_check(world.wall_nodes.size() == initial_count, "removed segment reclaimed")

	if "--capture" in OS.get_cmdline_user_args():
		await _capture(world, cfg, point)
	print("WALL_VISUAL_SMOKE ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 2)


func _capture(world: WorldBuilder, cfg: ConfigDB, point: Vector2) -> void:
	var rig := CameraRig.new()
	root.add_child(rig)
	rig.setup(cfg)
	rig.follow(Vector2(0, -17), 0.0, true)
	rig.camera.size = 23
	world.update_occlusion(rig.camera.global_position, Vector2(0, -11))
	await _save("godot_wall_v2_arc.png")

	# Exterior 3/4, testing the orthographic ray at a point just behind the center wall.
	var camera := rig.camera
	camera.position = Vector3.ZERO
	camera.global_position = Vector3(point.x + 3.8, 5.9, point.y - 8.0)
	camera.look_at(Vector3(point.x, 2.0, point.y), Vector3.UP)
	camera.size = 7.0
	await _save("godot_wall_v2_detail.png")
	var player_pos := point + Vector2(-0.5, 1.2)
	var marker := MeshInstance3D.new()
	marker.mesh = CapsuleMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.85, 0.97)
	mat.emission_enabled = true
	mat.emission = mat.albedo_color
	mat.emission_energy_multiplier = 0.35
	marker.material_override = mat
	world.add_child(marker)
	marker.position = Vector3(player_pos.x, 0.9, player_pos.y)
	world.update_occlusion(camera.global_position, player_pos)
	_check(_material_mode(world, world.wall_nodes.size() / 2, true), "orthographic view fades center wall")
	await _save("godot_wall_v2_occluded.png")


func _save(file_name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	_check(img.save_png("res://art/review/wall/" + file_name) == OK, "save " + file_name)
