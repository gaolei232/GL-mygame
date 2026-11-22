extends Node
## 背包探针：真实 GameApp + InventoryPanel（按格占位版）。

var app: Node
var frames := 0
var checks := 0
var failures := 0
var t0 := 0.0
var t1 := 0.0
var items: Array = []


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _press(code: int) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.physical_keycode = code
		ev.keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)


func _process(_dt: float) -> void:
	frames += 1
	match frames:
		2:
			app.sim.request("start_run")
		4:
			app.sim.request("return_city")
		6:
			# 一件普通（1×1）+ 一件传说（2×2）
			for tier in [0, 3]:
				var item = InventorySystem.roll_item(app.sim.state, app.sim.cfg, tier)
				InventorySystem.add_item(app.sim.state, item)
				items.append(item)
			var gear := 0
			for it in app.sim.state.items:
				if not InventorySystem.is_resource(it):
					gear += 1
			_ok(gear == 2, "背包里有 2 件装备（资源堆另算）")
			# 资源堆各占 1 格（开局 90 弹药 = 1 格）
			var res_cells := 0
			for it in app.sim.state.items:
				if InventorySystem.is_resource(it):
					res_cells += 1
			_ok(InventorySystem.bag_used_cells(app.sim.state) == 5 + res_cells,
				"占位按稀有度：1×1 + 2×2 + 资源堆",
				"used=%d res=%d" % [InventorySystem.bag_used_cells(app.sim.state), res_cells])
		8:
			_press(KEY_B)
		10:
			_ok(app.bag.visible, "按 B 打开背包")
			_ok(app.bag._cap.text.find("/ 10 格") >= 0, "容量按格显示", app.bag._cap.text)
			_ok(app.bag._bag_area.get_child_count() == app.sim.state.items.size(),
				"网格里 = 背包物品数",
				"%d/%d" % [app.bag._bag_area.get_child_count(), app.sim.state.items.size()])
			# 传说件应占 2×2（按钮宽度 > 1 格）
			var big := 0
			for c in app.bag._bag_area.get_children():
				if c is Button and (c as Button).size.x > 86.0:
					big += 1
			_ok(big == 1, "2×2 物品的按钮跨两格", "big=%d" % big)
			t0 = app.sim.state.phase_time
		12:
			_ok(is_equal_approx(t0, app.sim.state.phase_time), "背包打开时 sim 冻结",
				"%.3f -> %.3f" % [t0, app.sim.state.phase_time])
			app.bag.equip_requested.emit(items[0].uid)
		14:
			_ok(app.sim.state.equipped.has(items[0].uid), "点击装备生效（走信号回 app）")
			_ok(app.bag._stats.text.find("伤害") >= 0 and app.bag._stats.text.find("移速") >= 0,
				"背包底部有属性合计", app.bag._stats.text)
			var before_coin: int = app.sim.state.coin
			var price: int = int(items[1].sell)
			app.bag.sell_requested.emit(items[1].uid)
			var gear_left := 0
			for it in app.sim.state.items:
				if not InventorySystem.is_resource(it):
					gear_left += 1
			_ok(gear_left == 1, "卖出后装备少一件")
			_ok(app.sim.state.coin == before_coin + price, "卖出加金币",
				"%d -> %d（+%d）" % [before_coin, app.sim.state.coin, price])
			var res_cells2 := 0
			for it in app.sim.state.items:
				if InventorySystem.is_resource(it):
					res_cells2 += 1
			_ok(InventorySystem.bag_used_cells(app.sim.state) == 1 + res_cells2,
				"卖出 2×2 后占用回落到 1 格 + 资源堆",
				"used=%d res=%d" % [InventorySystem.bag_used_cells(app.sim.state), res_cells2])
		16:
			_press(KEY_B)
		18:
			_ok(not app.bag.visible, "再按 B 关闭背包")
			t1 = app.sim.state.phase_time
		20:
			_ok(app.sim.state.phase_time > t1, "关闭后 sim 恢复推进",
				"%.3f -> %.3f" % [t1, app.sim.state.phase_time])
			_press(KEY_B)
		22:
			_ok(app.bag.visible, "再次打开")
			_press(KEY_ESCAPE)
		24:
			_ok(not app.bag.visible, "Esc 也能关背包")
			PhaseMachine.enter(app.sim.state, GameState.Phase.WAVE, app.sim.cfg, app.sim.bus)
			_press(KEY_B)
		26:
			_ok(app.bag.visible, "战斗期也能开背包")
			t0 = app.sim.state.phase_time
		28:
			_ok(is_equal_approx(t0, app.sim.state.phase_time), "战斗期开背包同样冻结 sim")
			_press(KEY_B)
		30:
			app._return_to_title()
			_press(KEY_B)
		32:
			_ok(not app.bag.visible, "主菜单（TITLE）不响应 B")
			print("CHECKS %d, FAILURES %d" % [checks, failures])
			print("BAG_UI %s" % ("PASS" if failures == 0 else "FAIL"))
			get_tree().quit(0 if failures == 0 else 2)