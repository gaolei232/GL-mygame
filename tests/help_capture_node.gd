extends Node
## 验收截图：帮助面板 + 开箱后箱子保留。

var app: Node
var frames := 0


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)


func _process(_dt: float) -> void:
	frames += 1
	if frames == 2:
		app.sim.request("start_run")
	elif frames == 6:
		for e in app.sim.state.enemies:
			e.alive = false
		# 站到最近的普通箱，扫完并拿走一半，然后走开 —— 箱子应仍在
		for i in range(app.sim.state.loot_boxes.size()):
			var b: Dictionary = app.sim.state.loot_boxes[i]
			if String(b["tier"]) == "common":
				app.sim.state.player.pos = b["pos"]
				break
	elif frames == 10:
		for k in range(400):
			app.sim.step(0.05, {"move": Vector2.ZERO})
			if bool(app.sim.state.loot_boxes[0]["opened"]):
				break
		# 拿第一件，留一件
		var box: Dictionary = app.sim.state.loot_boxes[0]
		for ii in range(box["items"].size()):
			if bool(box["items"][ii]["revealed"]):
				app.sim.take_loot(0, ii)
				break
		# 走开 20m，箱子应该还在（没拿空）
		app.sim.state.player.pos = app.sim.state.player.pos + Vector2(20, 0)
	elif frames == 30:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://shots/_shot_box_kept.png")
		print("shot box_kept opened=%s" % str(app.sim.state.loot_boxes[0]["opened"]))
		app.help.call("open")
	elif frames == 42:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://shots/_shot_help.png")
		print("shot help")
		get_tree().quit(0)