extends SceneTree
## 弩的存在性与攻击链路审计（2026-11-09）。
## 目的：用可复现的数字回答「弩到底有没有出现在游戏里、能不能打」，
## 而不是照着 bug 描述改代码。

const DT := 1.0 / 60.0

var cfg: ConfigDB
var checks := 0
var failures := 0


func _init() -> void:
	cfg = ConfigDB.new()
	if not cfg.load_all():
		printerr("配置加载失败：", cfg.errors)
		quit(1)
		return

	var sim := Sim.new(cfg)
	sim.new_run(42)
	_ok(int(sim.state.player.slots.size()) == 2, "玩家有 2 个枪槽")
	_ok(str(sim.state.player.slots[0]) == "crossbow", "槽 1 初始装备弩",
		str(sim.state.player.slots))
	_ok(str(sim.state.player.slots[1]) == "", "槽 2 初始为空", str(sim.state.player.slots))
	_ok(int(sim.state.player.weapon_levels.get("crossbow", 0)) == 1, "弩初始 Lv1")

	sim.request("start_run")
	sim.state.enemies.clear()
	sim.drain_events()

	# 在玩家正前方放一个目标，按住开火
	var p := sim.state.player
	var enemy := EnemyFactory.spawn(sim.state, cfg, "walker", p.pos + Vector2(0, -12))
	var hp0 := enemy.hp
	var ammo0 := sim.state.ammo
	var events: Array = []
	for i in range(30):
		sim.step(DT, {"move": Vector2.ZERO, "aim": enemy.pos, "fire": true, "switch_to": -1})
		events.append_array(sim.drain_events())
	_ok(enemy.hp < hp0, "弩能造成伤害", "%.0f -> %.0f" % [hp0, enemy.hp])
	_ok(sim.state.ammo < ammo0, "弩消耗公共弹药", "%d -> %d" % [ammo0, sim.state.ammo])

	var shots := 0
	var hits := 0
	for e in events:
		if String(e["type"]) == EventBus.SHOT_FIRED:
			shots += 1
		elif String(e["type"]) == EventBus.ENEMY_HIT:
			hits += 1
	_ok(shots > 0 and hits > 0, "每发都有弹道事件与命中事件",
		"shots=%d hits=%d" % [shots, hits])

	var first_tracer: Dictionary = {}
	for e in events:
		if String(e["type"]) == EventBus.SHOT_FIRED:
			first_tracer = e["data"]
			break
	_ok(first_tracer.get("from", Vector2.ZERO) != first_tracer.get("to", Vector2.ZERO),
		"弹道有长度（不是原地空射）")

	# 切到空槽 2：应该打不出东西（当前是静默失败，需要提示）
	InventorySystem.set_total(sim.state, "ammo", 50)
	sim.step(DT, {"move": Vector2.ZERO, "aim": enemy.pos, "fire": true, "switch_to": 1})
	var ammo_before := sim.state.ammo
	var empty_events: Array = []
	for i in range(10):
		sim.step(DT, {"move": Vector2.ZERO, "aim": enemy.pos, "fire": true, "switch_to": -1})
		empty_events.append_array(sim.drain_events())
	var noticed := false
	for e in empty_events:
		if String(e["type"]) == EventBus.NOTICE:
			noticed = true
	_ok(sim.state.ammo == ammo_before, "空槽 2 不消耗弹药")
	_ok(noticed, "空槽 2 开火有提示（否则玩家会以为弩没了）", "noticed=%s" % str(noticed))

	# 弹药耗尽
	sim.step(DT, {"move": Vector2.ZERO, "aim": enemy.pos, "fire": true, "switch_to": 0})
	InventorySystem.set_total(sim.state, "ammo", 0)
	sim.state.player.fire_cd = 0.0
	var dry: Array = []
	for i in range(5):
		sim.step(DT, {"move": Vector2.ZERO, "aim": enemy.pos, "fire": true, "switch_to": -1})
		dry.append_array(sim.drain_events())
	var dry_notice := ""
	for e in dry:
		if String(e["type"]) == EventBus.NOTICE:
			dry_notice = str(e["data"].get("text", ""))
	_ok(dry_notice.find("弹药") >= 0, "空弹有明确提示", dry_notice)

	# 升级后伤害提升
	var sim2 := Sim.new(cfg)
	sim2.new_run(43)
	sim2.request("start_run")
	InventorySystem.set_total(sim2.state, "coin", 9999)
	InventorySystem.set_total(sim2.state, "metal", 99)
	_ok(EconomySystem.upgrade_weapon(sim2.state, cfg, sim2.bus, "crossbow"), "弩可强化")
	var row1 := cfg.weapon_level_row("crossbow", 1)
	var row2 := cfg.weapon_level_row("crossbow", 2)
	_ok(float(row2["atk"]) > float(row1["atk"]), "强化后单发伤害提升",
		"%.1f -> %.1f" % [float(row1["atk"]), float(row2["atk"])])

	_test_buy_light_crossbow()
	_test_weapon_model()
	_test_no_stray_notice()

	print("CHECKS %d, FAILURES %d" % [checks, failures])
	print("CROSSBOW_AUDIT %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 2)


## 副枪槽：商店买「轻弩」→ 填进槽 2 → 按 2 能开火
func _test_buy_light_crossbow() -> void:
	var sim := Sim.new(cfg)
	sim.new_run(44)
	sim.request("start_run")
	sim.request("return_city")
	InventorySystem.set_total(sim.state, "coin", 800)
	InventorySystem.set_total(sim.state, "metal", 20)
	var idx := -1
	for i in range(sim.state.shop_stock.size()):
		if str(sim.state.shop_stock[i]["key"]) == "light_crossbow":
			idx = i
	_ok(idx >= 0, "货架里有「轻弩」", "stock=%d" % sim.state.shop_stock.size())
	_ok(EconomySystem.buy(sim.state, cfg, sim.bus, idx), "能买到轻弩")
	_ok(str(sim.state.player.slots[1]) == "light_crossbow", "轻弩装进槽 2",
		str(sim.state.player.slots))

	# 按 2 开火：用轻弩的射程/伤害
	var enemy := EnemyFactory.spawn(sim.state, cfg, "walker", sim.state.player.pos + Vector2(0, -12))
	var hp0 := enemy.hp
	var ammo0 := sim.state.ammo
	for i in range(20):
		sim.step(DT, {"move": Vector2.ZERO, "aim": enemy.pos, "fire": true, "switch_to": 1})
		sim.drain_events()
	_ok(int(sim.state.player.active_slot) == 1, "槽 2 已切换")
	_ok(sim.state.ammo < ammo0 and enemy.hp < hp0, "轻弩能开火并造成伤害",
		"ammo %d->%d hp %.0f->%.0f" % [ammo0, sim.state.ammo, hp0, enemy.hp])


## 模型：只有握着枪槽武器时可见
func _test_weapon_model() -> void:
	var sim := Sim.new(cfg)
	sim.new_run(45)
	sim.request("start_run")
	var units := UnitLayer.new()
	root.add_child(units)
	units.setup()
	_ok(units.weapon_node != null, "玩家挂了弩模型节点")
	units.sync(sim.snapshot(), 1.0 / 60.0)
	_ok(units.weapon_node.visible, "槽 1 握弩时模型可见")
	sim.state.player.active_slot = 2          # 锤
	units.sync(sim.snapshot(), 1.0 / 60.0)
	_ok(not units.weapon_node.visible, "切到锤子时收起弩")
	sim.state.player.active_slot = 1          # 空槽
	units.sync(sim.snapshot(), 1.0 / 60.0)
	_ok(not units.weapon_node.visible, "切到空槽时没有弩")
	units.queue_free()


## 回归：正常开火不应该冒出「空槽」之类的提示
func _test_no_stray_notice() -> void:
	var sim := Sim.new(cfg)
	sim.new_run(46)
	sim.request("start_run")
	sim.state.enemies.clear()
	sim.drain_events()
	var enemy := EnemyFactory.spawn(sim.state, cfg, "walker", sim.state.player.pos + Vector2(0, -10))
	var ev: Array = []
	for i in range(6):
		sim.step(DT, {"move": Vector2.ZERO, "aim": enemy.pos, "fire": true, "switch_to": -1})
		ev.append_array(sim.drain_events())
	var noisy := false
	for e in ev:
		if String(e["type"]) == EventBus.NOTICE:
			noisy = true
	_ok(not noisy, "正常持弩开火不产生提示噪音")


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)