extends Node
## 建造系统截图：建造面板（含可建造/资源不足状态）、放置预览、木箱 5×5 仓库。

var app: Node
var frames := 0


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("shot ", path)


func _process(_dt: float) -> void:
	frames += 1
	match frames:
		2:
			app.sim.request("start_run")
		4:
			app.sim.request("return_city")
		6:
			InventorySystem.set_total(app.sim.state, "coin", 5000)
			InventorySystem.set_total(app.sim.state, "brick", 200)
			InventorySystem.set_total(app.sim.state, "metal", 100)
			app.hud.invalidate()
		7:
			# 先摆一个木箱、一座炮台、一段自建墙、一次背包扩容
			BuildSystem.build(app.sim.state, app.sim.cfg, app.sim.bus, "crate", Vector2(8, -8))
			BuildSystem.build(app.sim.state, app.sim.cfg, app.sim.bus, "cannon", Vector2(12, -8))
			BuildSystem.build(app.sim.state, app.sim.cfg, app.sim.bus, "wall", Vector2(0, -14))
			BuildSystem.build(app.sim.state, app.sim.cfg, app.sim.bus, "backpack", Vector2.ZERO)
		9:
			# 选中木箱，光标放在空地上显示合法绿色预览
			app._on_build_requested("crate")
			app._aim = Vector2(6, -6)
		11:
			await _shot("res://shots/_shot_build_panel.png")
			# 再模拟资源不足：把金币清零，让面板显示置灰原因
			app._cancel_build_mode()
			InventorySystem.set_total(app.sim.state, "coin", 0)
		13:
			await _shot("res://shots/_shot_build_poor.png")
			InventorySystem.set_total(app.sim.state, "coin", 5000)
			app._on_build_requested("crate")
			app._aim = Vector2(6, -6)
		16:
			app._cancel_build_mode()
			# 往木箱里放点东西，打开仓库截图
			var crate: GameState.BuildingState = app.sim.state.buildings[0]
			BuildSystem.deposit_resource(app.sim.state, app.sim.cfg, app.sim.bus, crate.id, "coin", 320)
			BuildSystem.deposit_resource(app.sim.state, app.sim.cfg, app.sim.bus, crate.id, "brick", 40)
			for tier in [0, 2]:
				var item := InventorySystem.roll_item(app.sim.state, app.sim.cfg, tier)
				InventorySystem.add_item(app.sim.state, item)
				BuildSystem.deposit_item(app.sim.state, app.sim.cfg, app.sim.bus, crate.id, item.uid)
			app.sim.state.player.pos = Vector2(8, -5)
		18:
			app._toggle_crate()
		20:
			await _shot("res://shots/_shot_crate.png")
			app._close_crate()
		22:
			get_tree().quit(0)