extends Node
## 界面反馈探针：真实 GameApp。

var app: Node
var frames := 0
var checks := 0
var failures := 0


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _find_button(text_part: String) -> Button:
	for c in app.hud._panel_box.get_children():
		if c.is_queued_for_deletion():
			continue
		if c is Button and (c as Button).text.find(text_part) >= 0:
			return c as Button
	return null


func _process(_dt: float) -> void:
	frames += 1
	match frames:
		2:
			app.sim.request("start_run")
		4:
			app.sim.request("return_city")        # BUILD
		6:
			# 1) 升级价目注入 + 资源不足时按钮置灰
			var costs: Dictionary = app.hud.upgrade_costs
			_ok(costs.has("hammer") and costs.has("crossbow") and costs.has("crystal"),
				"升级价目已注入 HUD", str(costs.keys()))
			InventorySystem.set_total(app.sim.state, "coin", 0)
			InventorySystem.set_total(app.sim.state, "metal", 0)
			app.hud.update_snapshot(app.sim.snapshot())
			var b1 := _find_button("强化锤")
			_ok(b1 != null and b1.disabled, "没钱时「强化锤」置灰（不是因为点了没反应）",
				"disabled=%s" % str(b1.disabled) if b1 != null else "miss")
			var shop_disabled := 0
			for c in app.hud._panel_box.get_children():
				if c is Button and (c as Button).text.find("资源不足") >= 0:
					shop_disabled += 1
			_ok(shop_disabled >= 2, "买不起的货架项标「资源不足」并置灰", "n=%d" % shop_disabled)
		8:
			InventorySystem.set_total(app.sim.state, "coin", 5000)
			InventorySystem.set_total(app.sim.state, "metal", 99)
			app.hud.update_snapshot(app.sim.snapshot())
			var b2 := _find_button("强化锤")
			_ok(b2 != null and not b2.disabled, "钱够了按钮恢复可点")
			_ok(b2 != null and b2.text.find("金") >= 0, "按钮上写清价格", b2.text if b2 != null else "")
		10:
			# 2) 购买回执：直接喂 PURCHASE 事件，等价于点了货架
			var before: int = app.hud._toasts.size()
			app._apply_events([{"type": EventBus.PURCHASE, "data": {"key": "brick_pack", "name": "砖块包 ×20"}}])
			_ok(app.hud._toasts.size() == before + 1, "买砖块包会弹一条回执",
				"toasts=%d" % app.hud._toasts.size())
			var last: Dictionary = app.hud._toasts[app.hud._toasts.size() - 1]
			_ok(str(last["text"]).find("已购买") >= 0 and str(last["text"]).find("砖块包") >= 0,
				"回执写清买了什么", str(last["text"]))

			var n2: int = app.hud._toasts.size()
			app._apply_events([{"type": EventBus.PURCHASE, "data": {"key": "crystal_upgrade", "level": 2}}])
			_ok(app.hud._toasts.size() == n2 + 1 and str(app.hud._toasts[-1]["text"]).find("水晶") >= 0,
				"水晶升级有回执")

			var n3: int = app.hud._toasts.size()
			app._apply_events([{"type": EventBus.PURCHASE, "data": {"key": "trait_common", "name": "普通词条"}}])
			_ok(app.hud._toasts.size() == n3, "词条不重复弹两条（ITEM_GAINED 已提示）")
		12:
			# 3) 点击涟漪：UI 点击不打枪，只留一圈涟漪
			app._fire_buffer = 0.0
			app._on_left_click(Vector2(300, 200), true)
			_ok(app._fire_buffer == 0.0, "点 UI 不会带出一枪", "fire_buffer=%.2f" % app._fire_buffer)
			_ok(app.hud._clicks.size() == 1, "点 UI 有涟漪反馈", "clicks=%d" % app.hud._clicks.size())
			app._on_left_click(Vector2(700, 400), false)
			_ok(app._fire_buffer > 0.0, "点空地仍然正常开枪", "fire_buffer=%.2f" % app._fire_buffer)
			app.hud._process(0.3)
			_ok(app.hud._clicks.is_empty(), "涟漪 0.22s 后自动清掉")
			print("CHECKS %d, FAILURES %d" % [checks, failures])
			print("FEEDBACK_UI %s" % ("PASS" if failures == 0 else "FAIL"))
			get_tree().quit(0 if failures == 0 else 2)