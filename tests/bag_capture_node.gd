extends Node

var app: Node
var frames := 0

func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)

func _process(_dt: float) -> void:
	frames += 1
	match frames:
		15:
			app.sim.request("start_run")
		25:
			app.sim.request("return_city")
		30:
			# 造一批物品：不同稀有度各一件，外加已装备一件
			app.sim.state.wave_index = 3
			for tier in [0, 1, 2, 3]:
				var it = InventorySystem.roll_item(app.sim.state, app.sim.cfg, tier)
				it.kind = "trait"
				it.stat = "dmg"
				it.value = 0.08 * [1.0, 1.25, 1.6, 2.1][tier]
				it.desc = "伤害 +%d%%" % int(it.value * 100)
				InventorySystem.add_item(app.sim.state, it)
			InventorySystem.equip(app.sim.state, app.sim.cfg, app.sim.state.items[2].uid)
		40:
			app._toggle_bag()
		70:
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			img.save_png("res://shots/_shot_bag.png")
			print("shot bag")
			get_tree().quit(0)
