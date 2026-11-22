extends SceneTree
## P1-4 无头断言：稀有度抽取 / 词条数值 / 装备位 / 背包容量 / 卖出 / 战斗生效。

const DT := 1.0 / 60.0

var sim: Sim
var failures := 0
var checks := 0


func _init() -> void:
	var cfg := ConfigDB.new()
	if not cfg.load_all():
		printerr("配置加载失败：", cfg.errors)
		quit(1)
		return
	sim = Sim.new(cfg)

	_test_config()
	_test_tier_by_wave()
	_test_value_scaling()
	_test_equip_limits()
	_test_damage_applied()
	_test_bag_capacity_and_sell()
	_test_shop_trait_slot()

	print("CHECKS %d, FAILURES %d" % [checks, failures])
	print("P14_SMOKE %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 2)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _fresh(wave_index: int = 1, seed_value: int = 9001) -> void:
	sim.new_run(seed_value)
	sim.request("start_run")
	sim.state.wave_index = wave_index
	sim.state.enemies.clear()


func _test_config() -> void:
	_ok(sim.cfg.rarity_rows().size() == 4, "稀有度 4 档")
	_ok(sim.cfg.item_defs().size() == 7, "词条池 7 条", str(sim.cfg.item_defs().size()))
	_ok(sim.cfg.backpack_capacity() == 10, "背包容量 10")
	_ok(sim.cfg.slot_capacity("trait") == 2 and sim.cfg.slot_capacity("attachment") == 1,
		"装备位 2 词条 + 1 配件")


func _test_tier_by_wave() -> void:
	_fresh(1)
	var high := 0
	for i in range(300):
		var it := InventorySystem.roll_item(sim.state, sim.cfg)
		if it.tier >= 2:
			high += 1
	_ok(high == 0, "第 1 波不会掉稀有以上", "high=%d" % high)

	_fresh(5)
	var low := 0
	for i in range(300):
		var it := InventorySystem.roll_item(sim.state, sim.cfg)
		if it.tier <= 0:
			low += 1
	_ok(low == 0, "第 5 波不会掉普通", "low=%d" % low)


func _test_value_scaling() -> void:
	_fresh(3)
	var found := false
	for i in range(200):
		var it := InventorySystem.roll_item(sim.state, sim.cfg, 3)   # 强制传说
		if it.def_id == "sharp":
			found = true
			_ok(absf(it.value - 0.08 * 2.1) < 1e-6, "传说锋芒 = 8%×2.1",
				"value=%.4f" % it.value)
			break
	if not found:
		_ok(false, "传说锋芒 = 8%×2.1", "未抽到 sharp")


func _test_equip_limits() -> void:
	_fresh(1)
	# 2026-11-15：资源改为占背包格，10 格里放不下 3 件词条；
	# 本用例测的是装备位上限，先换成 18 格背包排除容量干扰。
	InventorySystem.resize_bag(sim.state, 6, 3)
	var items: Array = []
	for i in range(3):
		var it := InventorySystem.roll_item(sim.state, sim.cfg, 0)
		it.def_id = "sharp"
		it.kind = "trait"
		it.stat = "dmg"
		it.value = 0.10
		InventorySystem.add_item(sim.state, it)
		items.append(it)          # 背包里还有资源堆，不能再用 items[0..2] 当词条
	var e1 := InventorySystem.equip(sim.state, sim.cfg, items[0].uid)
	var e2 := InventorySystem.equip(sim.state, sim.cfg, items[1].uid)
	var e3 := InventorySystem.equip(sim.state, sim.cfg, items[2].uid)
	_ok(e1 and e2, "可装 2 个词条")
	_ok(not e3, "第 3 个词条被拒绝（装备位已满）")
	_ok(absf(float(sim.state.mods["dmg"]) - 1.20) < 1e-6, "同类词条相加 = ×1.20",
		"dmg=%.3f" % float(sim.state.mods["dmg"]))

	var att := InventorySystem.roll_item(sim.state, sim.cfg, 0)
	att.kind = "attachment"
	att.stat = "dmg"
	att.value = 0.12
	InventorySystem.add_item(sim.state, att)
	_ok(InventorySystem.equip(sim.state, sim.cfg, att.uid), "可装 1 个配件")
	_ok(absf(float(sim.state.mods["dmg"]) - 1.20 * 1.12) < 1e-6,
		"跨类相乘 = 1.20×1.12", "dmg=%.4f" % float(sim.state.mods["dmg"]))

	var second := InventorySystem.roll_item(sim.state, sim.cfg, 0)
	second.kind = "attachment"
	InventorySystem.add_item(sim.state, second)
	_ok(not InventorySystem.equip(sim.state, sim.cfg, second.uid), "第 2 个配件被拒绝")


func _test_damage_applied() -> void:
	_fresh(1)
	InventorySystem.recompute(sim.state)          # 清空装备 → 基础值
	var base_dmg := _measure_shot()

	var it := InventorySystem.roll_item(sim.state, sim.cfg, 0)
	it.kind = "trait"
	it.stat = "dmg"
	it.value = 0.50
	InventorySystem.add_item(sim.state, it)
	InventorySystem.equip(sim.state, sim.cfg, it.uid)
	var boosted := _measure_shot()
	_ok(absf(boosted / maxf(1.0, base_dmg) - 1.5) < 0.02, "装备后单发伤害 ×1.5",
		"base=%.1f boosted=%.1f" % [base_dmg, boosted])


func _measure_shot() -> float:
	sim.state.enemies.clear()
	InventorySystem.set_total(sim.state, "ammo", 30)
	sim.state.player.fire_cd = 0.0
	sim.state.player.fire_cd = 0.0
	sim.state.player.pos = Vector2(6, 0)
	var enemy := EnemyFactory.spawn(sim.state, sim.cfg, "walker", Vector2(6, -14))
	enemy.hp = 10000.0
	enemy.max_hp = 10000.0
	var before := enemy.hp
	sim.step(DT, {"move": Vector2.ZERO, "aim": enemy.pos, "fire": true, "switch_to": 0})
	sim.drain_events()
	return before - enemy.hp


func _test_bag_capacity_and_sell() -> void:
	_fresh(1)
	for i in range(10):
		InventorySystem.add_item(sim.state, InventorySystem.roll_item(sim.state, sim.cfg, 0))
	_ok(sim.state.items.size() == 10, "背包填满 10 格")
	var overflow := InventorySystem.roll_item(sim.state, sim.cfg, 0)
	_ok(not InventorySystem.add_item(sim.state, overflow), "第 11 件被拒绝")

	var target: GameState.Item = null
	for it in sim.state.items:
		if not InventorySystem.is_resource(it):
			target = it
			break
	var coin_before := sim.state.coin
	var gear_before := 0
	for it in sim.state.items:
		if not InventorySystem.is_resource(it):
			gear_before += 1
	var gained := InventorySystem.sell(sim.state, target.uid)
	var gear_after := 0
	for it in sim.state.items:
		if not InventorySystem.is_resource(it):
			gear_after += 1
	_ok(gear_after == gear_before - 1 and sim.state.coin == coin_before + gained,
		"卖出：装备 -1、金币 +售价（金币进背包堆）", "+%d" % gained)


func _test_shop_trait_slot() -> void:
	_fresh(2)
	EconomySystem.roll_shop(sim.state, sim.cfg)
	var has_trait := false
	for slot in sim.state.shop_stock:
		if String(slot["key"]) in ["trait_common", "bag_upgrade"]:
			has_trait = true
	_ok(has_trait, "第 2 波货架出现轮换位（普通词条或扩容背包）")

	# 背包满时购买必须被拒且不扣钱。
	# 注意：资源也是背包物品，必须先给钱再塞包，否则 set_total 自己就会被满包拒绝。
	InventorySystem.set_total(sim.state, "coin", 5000)
	InventorySystem.set_total(sim.state, "metal", 500)
	for i in range(12):
		InventorySystem.add_item(sim.state, InventorySystem.roll_item(sim.state, sim.cfg, 0))
	var coin_before := sim.state.coin
	EconomySystem.roll_shop(sim.state, sim.cfg)
	var idx := -1
	for i in range(sim.state.shop_stock.size()):
		if String(sim.state.shop_stock[i]["key"]) == "trait_common":
			idx = i
	var bought := EconomySystem.buy(sim.state, sim.cfg, sim.bus, idx) if idx >= 0 else true
	_ok(idx >= 0 and not bought and sim.state.coin == coin_before,
		"背包满时购买被拒且不扣钱", "coin %d -> %d" % [coin_before, sim.state.coin])
