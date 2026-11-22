extends Node
## 站到普通箱上扫一会儿，然后抓图（能看到已显现格 + 当前格进度）。

var app: Node
var frames := 0


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)


func _process(_dt: float) -> void:
	frames += 1
	match frames:
		2:
			app.sim.request("start_run")
		6:
			for box in app.sim.state.loot_boxes:
				if String(box["tier"]) == "common":
					app.sim.state.player.pos = box["pos"]
					break
			# 清掉追兵，免得拍摄途中被打断
			for e in app.sim.state.enemies:
				e.alive = false
		150:
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://shots/_shot_search.png")
			print("shot search")
			get_tree().quit(0)