extends Node
## 建造 UI 探针：面板列表 / 放置 / 拆除 / 木箱仓库。

var app: Node
var frames := 0
var checks := 0
var failures := 0
var coin_before := 0


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
			InventorySystem.set_total(app.sim.state, "coin", 5000)
			InventorySystem.set_total(app.sim.state, "brick", 200)
			InventorySystem.set_total(app.sim.state, "metal", 100)
			app.hud.invalidate()
		7:
			_ok(app.build_panel.visible, "建设期显示建造面板")
			_ok(app.build_panel._list.get_child_count() == 4, "列表 4 项",
				"%d" % app.build_panel._list.get_child_count())
			var texts := _card_texts()
			_ok(texts[0].find("木箱") >= 0 and texts[1].find("背包") >= 0
				and texts[2].find("城墙段") >= 0 and texts[3].find("炮台") >= 0,
				"四项名称正确", " | ".join(texts))
			_ok(texts[0].find("金 150") >= 0 and texts[0].find("≈240G") >= 0,
				"木箱卡片写明 150 金 + 240G 等价", texts[0])
			_ok(texts[2].find("本波 0/1") >= 0, "城墙卡片写明每波名额", texts[2])
			app._on_build_requested("crate")
		9:
			_ok(app._build_selected == "crate", "点击木箱卡片进入自由建造", app._build_selected)
			_ok(app.build_panel._free_build.button_pressed, "自由建造按钮同步为按下")
			_ok(app.build_layer._ghost.visible, "选中后出现放置预览")
			app._aim = Vector2(8, -8)
			app._place_selected()
		10:
			_ok(app.sim.state.buildings.size() == 1, "左键放置木箱成功",
				"%d" % app.sim.state.buildings.size())
			_ok(app._build_selected == "crate", "自由建造：放置后仍保持选中")
			_ok(app.sim.state.coin == 4850, "扣 150 金", "coin=%d" % app.sim.state.coin)
			_ok(app.build_layer._ghost.visible, "自由建造：放置后预览仍在")
			_ok(app.build_layer._roots.size() == 1, "木箱渲染节点已生成",
				"%d" % app.build_layer._roots.size())
			# 连续放第二个：自由建造不退出
			app._aim = Vector2(5, -8)
			app._place_selected()
		11:
			_ok(app.sim.state.buildings.size() == 2, "自由建造可以连续放第二个木箱",
				"%d" % app.sim.state.buildings.size())
			_ok(app.sim.state.coin == 4628, "第二个木箱扣 222 金（递增价）",
				"coin=%d" % app.sim.state.coin)
			app._toggle_free_build()
			_ok(app._build_selected == "", "V 退出自由建造")
			app._toggle_free_build()
			_ok(app._build_selected == "crate", "再按 V 重新进入自由建造")
			app._on_build_requested("backpack")
		12:
			_ok(app.sim.state.bag_rows == 4 and app.sim.state.bag_capacity == 20,
				"背包卡片点击后扩容到 5×4=20",
				"%dx%d" % [app.sim.state.bag_cols, app.sim.state.bag_rows])
			app._on_build_requested("wall")
		13:
			app._aim = Vector2(0, -14)
			app._place_selected()
			app._aim = Vector2(6, -12)
		14:
			_ok(app.sim.state.wall.size() == 8, "城墙卡片放置 1 段",
				"%d" % app.sim.state.wall.size())
			app._aim = Vector2(6, -12)
			app._hover_wall = -1
			app._build_info = BuildSystem.ui_state(app.sim.state, app.sim.cfg,
				app._build_selected, app._aim, app._demolish_mode)
			_ok(app._wall_hint().find("本波") >= 0, "建满后 HUD 提示本波已建满",
				app._wall_hint())
			var wall_card: Dictionary = _card(2)
			_ok(bool(wall_card.get("blocked", false)), "城墙卡片置灰",
				str(wall_card.get("reason", "")))

			app._on_build_requested("cannon")
		15:
			app._aim = Vector2(12, -8)
			app._place_selected()
		16:
			_ok(app.sim.state.buildings.size() == 3, "炮台放置成功",
				"%d" % app.sim.state.buildings.size())

			# 靠近木箱，等一帧 BuildSystem 更新 near_crate
			app.sim.state.player.pos = Vector2(8, -5)
		17:
			_ok(app.sim.state.near_crate >= 0, "3m 内识别木箱",
				"%d" % app.sim.state.near_crate)
			_ok(app.hud.snap.get("near_crate", -1) >= 0, "HUD 快照带 near_crate")
			app._toggle_crate()
		18:
			_ok(app.crate_panel.visible, "R 打开木箱仓库")
			_ok(app.crate_panel._grid.get_child_count() == 25, "仓库 5×5=25 格",
				"%d" % app.crate_panel._grid.get_child_count())
			_ok(app.crate_panel._title.text.find("木箱 #1") >= 0, "仓库标题带序号",
				app.crate_panel._title.text)
			coin_before = app.sim.state.coin
			app.crate_panel.deposit_resource.emit("coin", 100)
		19:
			_ok(app.sim.state.coin == coin_before - 100, "仓库存 100 金",
				"coin %d -> %d" % [coin_before, app.sim.state.coin])
			_ok(int(app.sim.state.buildings[0].stored[0].get("amount", 0)) == 100,
				"金币进箱内第 1 格")
			_press(KEY_R)
		20:
			_ok(not app.crate_panel.visible, "R 再按关闭仓库")
			_ok(not app.bag.visible, "仓库不会误开背包")

			# 拆除模式：X 打开，对准木箱左键拆
			app._on_demolish_toggled(true)
			_ok(app._demolish_mode, "X 进入拆除模式")
			app._aim = Vector2(8, -8)
		21:
			app._aim = Vector2(8, -8)
			app._build_info = BuildSystem.ui_state(app.sim.state, app.sim.cfg,
				app._build_selected, app._aim, app._demolish_mode)
			_ok(app._wall_hint().find("木箱") >= 0, "拆除提示写明返还与掉落",
				app._wall_hint())
			app._demolish_at_aim()
		22:
			_ok(app.sim.state.buildings.size() == 2, "木箱被拆除（剩第二箱 + 炮台）",
				"%d" % app.sim.state.buildings.size())
			_ok(app.sim.state.drops.size() >= 1, "箱内 100 金掉在地上",
				"%d" % app.sim.state.drops.size())
			_ok(app._demolish_mode, "拆除模式保持，方便连续拆")

			# 资源不足：面板卡片置灰并写原因
			app._cancel_build_mode()
			InventorySystem.set_total(app.sim.state, "coin", 0)
			InventorySystem.set_total(app.sim.state, "brick", 0)
		23:
			var poor: Dictionary = _card(0)
			_ok(bool(poor.get("blocked", false)), "资源不足时木箱卡片置灰")
			var text: String = str(_card_texts()[0])
			_ok(text.find("金币不足") >= 0 or text.find("砖块不足") >= 0,
				"卡片上写明缺什么", text)
			print("CHECKS %d, FAILURES %d" % [checks, failures])
			print("BUILDING_UI %s" % ("PASS" if failures == 0 else "FAIL"))
			get_tree().quit(0 if failures == 0 else 2)


func _card_texts() -> Array:
	var out: Array = []
	for c in app.build_panel._list.get_children():
		if c is Button:
			out.append((c as Button).text)
	return out


func _card(index: int) -> Dictionary:
	var info: Dictionary = BuildSystem.ui_state(app.sim.state, app.sim.cfg,
		app._build_selected, app._aim, app._demolish_mode)
	var items: Array = info.get("items", [])
	return items[index] if index >= 0 and index < items.size() else {}