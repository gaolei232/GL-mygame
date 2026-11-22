extends Node
## 拾取流程截图：把箱子扫完 -> 面板保持打开（已搜完 · 双击拾取）-> 双击一件 -> 划掉。
## 用来验收 2026-11-15「扫描完不自动入账、必须双击拾取」的改动。

var app: Node
var frames := 0
var box_index := -1
var took := false


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)


func _process(_dt: float) -> void:
	frames += 1
	if frames == 2:
		app.sim.request("start_run")
	elif frames == 6:
		for i in range(app.sim.state.loot_boxes.size()):
			var b: Dictionary = app.sim.state.loot_boxes[i]
			if String(b["tier"]) == "common":
				box_index = i
				app.sim.state.player.pos = b["pos"]
				break
		for e in app.sim.state.enemies:
			e.alive = false
	elif frames == 40:
		_scan_until_opened()
		var b2: Dictionary = app.sim.state.loot_boxes[box_index]
		print("opened=%s searching=%d near=%d" % [
			bool(b2["opened"]), int(app.sim.state.searching_box),
			int(app.sim.state.near_box)])
	elif frames == 120:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://shots/_shot_loot_take.png")
		print("shot loot_take")
		var b3: Dictionary = app.sim.state.loot_boxes[box_index]
		for ii in range(b3["items"].size()):
			var it: Dictionary = b3["items"][ii]
			if bool(it.get("revealed", false)) and not bool(it.get("taken", false)):
				app.sim.take_loot(box_index, ii)
				took = true
				break
	elif frames == 140:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://shots/_shot_loot_after_take.png")
		print("shot loot_after_take took=%s coin=%d" % [took, app.sim.state.coin])
		get_tree().quit(0)


func _scan_until_opened() -> void:
	var b: Dictionary = app.sim.state.loot_boxes[box_index]
	if bool(b["opened"]):
		return
	for k in range(400):
		app.sim.step(0.05, {"move": Vector2.ZERO})
		if bool(b["opened"]):
			return