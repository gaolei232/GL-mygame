extends Node
## 主菜单 / 建设期 / 自建城墙 / 暂停 / 设置 / 概率公示。窗口渲染专用。

var app: Node
var frames := 0


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)


func _shoot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)


func _process(_dt: float) -> void:
	frames += 1
	match frames:
		2:
			await _shoot("res://shots/_shot_title.png")
			print("shot title")
			app.sim.request("start_run")
		10:
			app.sim.request("return_city")        # 建设期
		12:
			await _shoot("res://shots/_shot_build.png")
			print("shot build")
		14:
			# 自建两段城墙（段数无上限，靠造价闸门）
			InventorySystem.set_total(app.sim.state, "coin", 2000)
			InventorySystem.set_total(app.sim.state, "brick", 100)
			EconomySystem.build_wall(app.sim.state, app.sim.cfg, app.sim.bus, Vector2(0, -14))
			EconomySystem.build_wall(app.sim.state, app.sim.cfg, app.sim.bus, Vector2(-7.5, -11))
			app.sim.state.player.pos = Vector2(0, -18)
		18:
			await _shoot("res://shots/_shot_build_wall.png")
			print("shot build_wall")
		20:
			app.set_paused(true)
		26:
			await _shoot("res://shots/_shot_pause.png")
			print("shot pause")
			app._open_settings()
		32:
			await _shoot("res://shots/_shot_settings.png")
			print("shot settings")
			app._close_settings()
			app._open_odds()
		38:
			await _shoot("res://shots/_shot_odds.png")
			print("shot odds")
			get_tree().quit(0)