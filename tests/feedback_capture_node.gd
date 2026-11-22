extends Node

var app: Node
var frames := 0

func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)

func _process(_dt: float) -> void:
	frames += 1
	match frames:
		20:
			app.sim.request("start_run")
		35:
			# 走过去开一个普通箱：验证开箱提示条
			for b in app.sim.state.loot_boxes:
				if String(b["tier"]) == "common":
					app.sim.state.player.pos = b["pos"]
					break
		45:
			app.sim.request("return_city")
		55:
			app.sim.request("start_wave")
		70:
			app.sim.state.player.pos = app.sim.state.wall[3].center + Vector2(-2.0, 3.0)
		700:
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			img.save_png("res://shots/_shot_feedback.png")
			print("shot feedback")
			get_tree().quit(0)
