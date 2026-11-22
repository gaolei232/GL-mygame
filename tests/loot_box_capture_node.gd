extends Node
## 宝箱实机验收截图：开局进入搜集期，拍普通箱（木箱）/精良箱（铁箱）与多个箱子同框。
## 用法：godot --path . --script res://tests/loot_box_capture.gd

var app: Node
var units_layer: Node
var free_cam: Camera3D


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)
	units_layer = app.units
	free_cam = Camera3D.new()
	free_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	free_cam.fov = 40.0
	free_cam.near = 0.05
	free_cam.far = 200.0
	add_child(free_cam)
	_run()


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://shots/_loot_box_%s.png" % name)
	print("shot _loot_box_%s.png %s" % [name, str(img.get_size())])


func _box_pos(tier: String) -> Vector2:
	for b in app.sim.snapshot()["loot"]:
		if str(b["tier"]) == tier:
			return b["pos"]
	return Vector2.ZERO


func _focus(pos: Vector2, size: float) -> void:
	app.cam.camera.current = true
	app.cam.ortho_size = size
	app.cam.camera.size = size
	app.cam.follow(pos, 1.0, true)


func _closeup(pos: Vector2, kind: String) -> void:
	var wy: float = TerrainHeight.at(pos.x, pos.y)
	free_cam.global_position = Vector3(pos.x - 1.5, wy + 1.55, pos.y - 1.9)
	free_cam.look_at(Vector3(pos.x, wy + 0.42, pos.y), Vector3.UP)
	free_cam.current = true
	print("closeup %s pos=%s" % [kind, str(pos)])


func _run() -> void:
	await _wait(0.5)
	app.sim.request("start_run")
	await _wait(0.8)
	if app.hud != null:
		app.hud.modulate.a = 0.0
	if units_layer.player_model != null:
		units_layer.player_model.visible = false
	await _wait(0.6)

	var boxes: Array = app.sim.snapshot()["loot"]
	print("boxes=", boxes.size(), " views=", units_layer.box_views.size())
	if boxes.is_empty():
		print("NO_BOXES")
		get_tree().quit(1)
		return
	var common := Vector2.ZERO
	var refined := Vector2.ZERO
	# 1) 实机视角：离玩家最近的一个箱子
	var ppos: Vector2 = app.sim.snapshot()["player"]["pos"]
	var best: Dictionary = boxes[0]
	var best_d := 1e9
	for b in boxes:
		var bp: Vector2 = b["pos"]
		var d := bp.distance_to(ppos)
		if d < best_d:
			best_d = d
			best = b
	_focus(best["pos"], 11.0)
	await _wait(0.2)
	# 把玩家挪到箱子旁（游戏相机跟玩家，这样拍到的才是真实游玩视角）
	app.sim.state.player.pos = best["pos"] + Vector2(1.7, 1.7)
	await _wait(0.8)
	await _shot("field")

	# 2) 近景：普通箱（木箱）/ 精良箱（铁箱）各取一个
	for b2 in boxes:
		if str(b2["tier"]) == "common" and common == Vector2.ZERO:
			common = b2["pos"]
		elif str(b2["tier"]) == "refined" and refined == Vector2.ZERO:
			refined = b2["pos"]
	_closeup(common if common != Vector2.ZERO else best["pos"], "common")
	await _wait(0.4)
	await _shot("wood_closeup")
	if refined != Vector2.ZERO:
		_closeup(refined, "refined")
		await _wait(0.4)
		await _shot("metal_closeup")

	print("LOOT_BOX_CAPTURE boxes=%d views=%d" % [boxes.size(), units_layer.box_views.size()])
	get_tree().quit(0)