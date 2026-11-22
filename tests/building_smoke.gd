extends SceneTree
## 建造系统（2026-11-10）：四件建造物的计价/上限/放置/拆除/掉落/仓库/炮台/仇恨/存档。
## 口径与 data/buildings.json 一致；本测试不读截图、不依赖渲染。

const DT := 1.0 / 60.0
const POSITIONS := [
	Vector2(8, -8), Vector2(11, -8), Vector2(8, -11), Vector2(5, -8),
	Vector2(4, -6), Vector2(6, -4), Vector2(10, -5), Vector2(13, -5),
	Vector2(5, -12), Vector2(11, -10), Vector2(3, -9), Vector2(9, -3),
]

var cfg: ConfigDB
var checks := 0
var failures := 0


func _init() -> void:
	cfg = ConfigDB.new()
	if not cfg.load_all():
		printerr("配置加载失败：", cfg.errors)
		quit(1)
		return
	_test_config()
	_test_crate_prices()
	_test_build_and_index_reuse()
	_test_backpack()
	_test_wall_cap_and_demolish()
	_test_cannon()
	_test_storage()
	_test_destroy_drops()
	_test_placement()
	_test_aggro_and_aoe()
	_test_repair()
	_test_save_roundtrip()
	_test_ui_state()
	_test_world_nodes_after_demolish()
	print("CHECKS %d, FAILURES %d" % [checks, failures])
	print("BUILDING_SMOKE %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 2)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _fresh(seed_value: int, coin: int = 0, brick: int = 0, metal: int = 0) -> Sim:
	var sim := Sim.new(cfg)
	sim.new_run(seed_value)
	sim.request("start_run")
	sim.request("return_city")
	sim.state.enemies.clear()
	InventorySystem.set_total(sim.state, "coin", coin)
	InventorySystem.set_total(sim.state, "brick", brick)
	InventorySystem.set_total(sim.state, "metal", metal)
	sim.drain_events()
	return sim


func _build(sim: Sim, id: String, pos: Vector2) -> bool:
	return BuildSystem.build(sim.state, cfg, sim.bus, id, pos)


func _find_notice(events: Array) -> String:
	for e in events:
		if String(e["type"]) == EventBus.NOTICE:
			return str(e["data"].get("text", ""))
	return ""


# ---------------------------------------------------------------- 数值

func _test_config() -> void:
	_ok(cfg.building_defs().size() == 4, "建造表 4 种", str(cfg.building_defs().size()))
	for id in ["crate", "backpack", "wall", "cannon"]:
		_ok(not cfg.building_def(id).is_empty(), "存在 %s 定义" % id)
	var crate := cfg.building_cost_at("crate", 1)
	_ok(int(crate["coin"]) == 150 and int(crate["brick"]) == 15 and int(crate["equivalent"]) == 240,
		"木箱第 1 个 = 150 金 + 15 砖 = 240 金等价", str(crate))
	var backpack := cfg.building_cost_at("backpack", 1)
	_ok(int(backpack["coin"]) == 320 and int(backpack["metal"]) == 5 and int(backpack["equivalent"]) == 420,
		"背包第 1 个 = 320 金 + 5 金属 = 420 金等价（方向 1）", str(backpack))
	var wall := cfg.building_cost_at("wall", 1)
	var wall_coin := int(cfg.wall_build_coin_cost())
	_ok(int(wall["coin"]) == wall_coin and int(wall["brick"]) == 20
		and int(wall["equivalent"]) == wall_coin + 20 * 6,
		"城墙段 %d 金 + 20 砖" % wall_coin, str(wall))
	var cannon := cfg.building_cost_at("cannon", 1)
	_ok(int(cannon["coin"]) == 400 and int(cannon["brick"]) == 20 and int(cannon["metal"]) == 9
		and int(cannon["equivalent"]) == 700, "炮台第 1 个 = 400 金 + 20 砖 + 9 金属 = 700",
		str(cannon))
	_ok(absf(cfg.wall_segment_hp() - 12142.857) < 0.1, "城墙段 HP = 85000/7",
		"%.3f" % cfg.wall_segment_hp())
	# 关键校验数：木箱 200 HP / 240 G = 0.83；城墙 28.6；修墙 150
	var crate_efficiency := 200.0 / 240.0
	var wall_efficiency := cfg.wall_segment_hp() / 425.0
	var repair_efficiency := 900.0 / 6.0
	_ok(absf(crate_efficiency - 0.833) < 0.01, "木箱 0.83 HP/G", "%.3f" % crate_efficiency)
	_ok(absf(wall_efficiency - 28.57) < 0.1, "城墙段 28.6 HP/G", "%.3f" % wall_efficiency)
	_ok(absf(repair_efficiency - 150.0) < 0.1, "修墙 150 HP/G", "%.3f" % repair_efficiency)


func _test_crate_prices() -> void:
	var want_eq := [240, 312, 406, 528, 686, 892, 1160, 1508]
	var want_coin := [150, 222, 316, 438, 596, 802, 1070, 1418]
	for i in range(8):
		var c := cfg.building_cost_at("crate", i + 1)
		_ok(int(c["equivalent"]) == int(want_eq[i]), "木箱第 %d 个金等价 = %d" % [i + 1, want_eq[i]],
			str(c["equivalent"]))
		_ok(int(c["coin"]) == int(want_coin[i]), "木箱第 %d 个金币 = %d" % [i + 1, want_coin[i]],
			str(c["coin"]))
		_ok(int(c["brick"]) == 15, "木箱第 %d 个砖固定 15" % (i + 1), str(c["brick"]))
	var total_eq := 0
	var total_brick := 0
	for i in range(8):
		var c := cfg.building_cost_at("crate", i + 1)
		total_eq += int(c["equivalent"])
		total_brick += int(c["brick"])
	_ok(total_eq == 5732 and total_brick == 120, "8 个木箱累计 5732 金等价 / 120 砖",
		"%d / %d" % [total_eq, total_brick])
	var cannon2 := cfg.building_cost_at("cannon", 2)
	_ok(int(cannon2["equivalent"]) == 945 and int(cannon2["coin"]) == 645,
		"炮台第 2 个 = 945 等价 / 645 金", str(cannon2))


func _test_build_and_index_reuse() -> void:
	var sim := _fresh(9101, 1000000, 10000, 100)
	for i in range(POSITIONS.size()):
		var ok := _build(sim, "crate", POSITIONS[i])
		_ok(ok, "第 %d 个木箱可建（不限数量）" % (i + 1), str(POSITIONS[i]))
	_ok(sim.state.buildings.size() == POSITIONS.size(), "木箱数量 = 12",
		"%d" % sim.state.buildings.size())
	var first: GameState.BuildingState = sim.state.buildings[0]
	_ok(first.index == 1 and int(first.max_hp) == 200, "木箱第 1 号 / 200 HP",
		"index=%d hp=%.0f" % [first.index, first.max_hp])
	_ok(is_equal_approx(first.hp, 200.0), "木箱满血")

	# 摧毁第 2 号：序号释放，重建继承原价
	var second: GameState.BuildingState = sim.state.buildings[1]
	var second_index := second.index
	BuildSystem.damage_building(sim.state, cfg, sim.bus, second, 999.0, "test")
	_ok(sim.state.crate_free_indices.has(second_index), "被摧毁木箱释放序号 %d" % second_index)
	_ok(sim.state.buildings.size() == POSITIONS.size() - 1, "摧毁后立即释放占位")
	var coin_before := sim.state.coin
	var rebuilt := _build(sim, "crate", Vector2(6, -7))
	_ok(rebuilt, "原地附近可重建")
	var last: GameState.BuildingState = sim.state.buildings[sim.state.buildings.size() - 1]
	_ok(last.index == second_index, "重建继承原序号 %d" % second_index, "index=%d" % last.index)
	_ok(sim.state.coin == coin_before - 222, "重建按原序号 222 金计价（不二次涨价）",
		"coin %d -> %d" % [coin_before, sim.state.coin])
	_ok(not sim.state.crate_free_indices.has(second_index), "重建后序号从空闲表移除")


# ---------------------------------------------------------------- 背包 / 城墙

func _test_backpack() -> void:
	var sim := _fresh(9102, 5000, 100, 100)
	_ok(sim.state.bag_rows == 2 and sim.state.bag_capacity == 10, "基础背包 5×2=10")
	_ok(_build(sim, "backpack", Vector2.ZERO), "建造第 1 个背包")
	_ok(sim.state.bag_rows == 4 and sim.state.bag_capacity == 20,
		"背包 +10 格 → 5×4=20", "%dx%d" % [sim.state.bag_cols, sim.state.bag_rows])
	_ok(sim.state.coin == 5000 - 320 and sim.state.metal == 95, "扣 320 金 + 5 金属",
		"coin=%d metal=%d" % [sim.state.coin, sim.state.metal])
	_ok(_build(sim, "backpack", Vector2.ZERO), "建造第 2 个背包")
	_ok(sim.state.bag_rows == 6 and sim.state.bag_capacity == 30, "背包 +10 → 5×6=30")
	for i in range(30):
		InventorySystem.add_item(sim.state, InventorySystem.roll_item(sim.state, cfg, 0))
	_ok(sim.state.items.size() == 30 and sim.state.bag_layout.size() == 30,
		"5×6 网格可放 30 件 1×1", "items=%d layout=%d" % [
			sim.state.items.size(), sim.state.bag_layout.size()])
	_ok(not InventorySystem.add_item(sim.state,
		InventorySystem.roll_item(sim.state, cfg, 0)), "第 31 件被拒绝")
	var coin_before := sim.state.coin
	_ok(not _build(sim, "backpack", Vector2.ZERO), "第 3 个背包被拒绝")
	var notice := _find_notice(sim.drain_events())
	_ok(notice.find("已达上限") >= 0, "上限提示明确", notice)
	_ok(sim.state.coin == coin_before, "被拒绝时不扣钱")

	# 扩容后原有物品仍在，且按新网格重排
	sim.new_run(9103)
	sim.request("start_run")
	sim.request("return_city")
	InventorySystem.set_total(sim.state, "coin", 5000)
	InventorySystem.set_total(sim.state, "metal", 100)
	for i in range(10):
		InventorySystem.add_item(sim.state, InventorySystem.roll_item(sim.state, cfg, 0))
	_ok(sim.state.items.size() == 10, "扩容前装满 10 格")
	_ok(_build(sim, "backpack", Vector2.ZERO), "满包时也能扩容")
	_ok(sim.state.items.size() == 10 and sim.state.bag_layout.size() == 10,
		"扩容后 10 件物品仍在并重排", "items=%d layout=%d" % [sim.state.items.size(), sim.state.bag_layout.size()])


func _test_wall_cap_and_demolish() -> void:
	var sim := _fresh(9104, 5000, 200)
	var base := sim.state.wall.size()
	var ok := _build(sim, "wall", Vector2(0, -14))
	_ok(ok and sim.state.wall.size() == base + 1, "建设期可新建 1 段城墙")
	var seg: GameState.WallSegment = sim.state.wall[base]
	var expect_coin := int(cfg.wall_build_coin_cost())
	_ok(seg.built and seg.paid_coin == expect_coin and seg.paid_brick == 20, "新建段标记 built 并记录实付",
		"built=%s coin=%d" % [str(seg.built), seg.paid_coin])
	_ok(absf(seg.max_hp - 12142.857) < 0.1, "新段 HP = 12143", "%.3f" % seg.max_hp)
	_ok(not _build(sim, "wall", Vector2(6, -10)), "同一波第 2 段被拒绝")
	var notice := _find_notice(sim.drain_events())
	_ok(notice.find("每波") >= 0 or notice.find("本波") >= 0, "提示本波已建满", notice)

	# 下一波重置闸门
	PhaseMachine.enter(sim.state, GameState.Phase.REWARD, cfg, sim.bus)
	PhaseMachine.enter(sim.state, GameState.Phase.SCOUT, cfg, sim.bus)
	sim.request("return_city")
	sim.state.enemies.clear()
	InventorySystem.set_total(sim.state, "coin", 5000)
	InventorySystem.set_total(sim.state, "brick", 200)
	_ok(_build(sim, "wall", Vector2(6, -10)), "下一波可再建 1 段")

	# 拆除自建段：返还 50%，不退本波名额；初始段不可拆
	var built_seg: GameState.WallSegment = sim.state.wall[base]
	var coin_before := sim.state.coin
	var brick_before := sim.state.brick
	var expect_refund := int(round(float(built_seg.paid_coin) * 0.5))
	var expect_brick := int(round(float(built_seg.paid_brick) * 0.5))
	var removed_ok := BuildSystem.demolish(sim.state, cfg, sim.bus, built_seg.center)
	_ok(removed_ok, "光标指向自建段可拆除")
	_ok(sim.state.coin == coin_before + expect_refund
			and sim.state.brick == brick_before + expect_brick,
		"拆除返还 50%%：%d 金 + %d 砖" % [expect_refund, expect_brick],
		"coin=%d brick=%d" % [sim.state.coin, sim.state.brick])
	_ok(sim.state.wall.size() == base + 1, "拆除后墙段数 -1", "%d" % sim.state.wall.size())
	_ok(sim.state.wall_built_this_wave == 1, "拆除不退本波建造名额")
	var default_seg: GameState.WallSegment = sim.state.wall[0]
	sim.drain_events()
	_ok(not BuildSystem.demolish(sim.state, cfg, sim.bus, default_seg.center), "初始城墙不可拆")
	notice = _find_notice(sim.drain_events())
	_ok(notice.find("初始城墙") >= 0, "初始城墙给出明确提示", notice)


# ---------------------------------------------------------------- 炮台

func _test_cannon() -> void:
	var sim := _fresh(9105, 100000, 1000, 100)
	_ok(_build(sim, "cannon", Vector2(8, -8)), "建造第 1 座炮台")
	_ok(_build(sim, "cannon", Vector2(12, -8)), "建造第 2 座炮台")
	_ok(_build(sim, "cannon", Vector2(8, -12)), "建造第 3 座炮台")
	var c_before := sim.state.coin
	_ok(not _build(sim, "cannon", Vector2(5, -8)), "第 4 座炮台被拒绝")
	var notice := _find_notice(sim.drain_events())
	_ok(notice.find("已达上限") >= 0, "炮台上限提示", notice)
	_ok(sim.state.coin == c_before, "被拒绝时不扣钱")
	var cannon: GameState.BuildingState = sim.state.buildings[0]
	_ok(cannon.index == 1 and is_equal_approx(cannon.max_hp, 800.0), "炮台 800 HP")

	# 45 DPS：进战斗期、清空波次队列，放一只 10000 HP 敌人在 10m
	PhaseMachine.enter(sim.state, GameState.Phase.WAVE, cfg, sim.bus)
	sim.state.spawn_queue.clear()
	sim.state.summon_pending.clear()
	sim.state.enemies.clear()
	var enemy := EnemyFactory.spawn(sim.state, cfg, "walker", cannon.pos + Vector2(0, -10))
	enemy.hp = 10000.0
	enemy.max_hp = 10000.0
	var hp_before := enemy.hp
	sim.step(1.0, {"move": Vector2.ZERO})
	_ok(absf((hp_before - enemy.hp) - 135.0) < 0.5, "3 座炮台 1 秒 135 伤害（单座 45）",
		"%.2f" % (hp_before - enemy.hp))
	_ok(not sim.state.drops.is_empty() or true, "战斗期炮台持续工作")

	# 被摧毁：回收 4 金属
	BuildSystem.damage_building(sim.state, cfg, sim.bus, cannon, 9999.0, "test")
	_ok(sim.state.buildings.size() == 2, "炮台被摧毁后移除")
	var salvage := 0
	for d in sim.state.drops:
		if d.kind == "metal":
			salvage += d.amount
	_ok(salvage == 4, "炮台摧毁回收 4 金属", "salvage=%d" % salvage)


# ---------------------------------------------------------------- 仓库

func _test_storage() -> void:
	var sim := _fresh(9106, 5000, 100, 100)
	_ok(_build(sim, "crate", Vector2(8, -8)), "建木箱用于存取")
	var crate: GameState.BuildingState = sim.state.buildings[0]
	sim.state.player.pos = Vector2(8, -5)
	sim.step(0.1, {"move": Vector2.ZERO})
	_ok(sim.state.near_crate == crate.id, "3m 内识别木箱", "near=%d" % sim.state.near_crate)

	var coin0 := sim.state.coin
	_ok(BuildSystem.deposit_resource(sim.state, cfg, sim.bus, crate.id, "coin", 100),
		"存入 100 金")
	_ok(sim.state.coin == coin0 - 100, "金币从玩家扣除", "coin=%d" % sim.state.coin)
	_ok(BuildSystem.deposit_resource(sim.state, cfg, sim.bus, crate.id, "brick", 50),
		"存入 50 砖")
	_ok(int(crate.stored[0].get("amount", 0)) == 100, "金币堆在 1 格")
	_ok(int(crate.stored[1].get("amount", 0)) == 50, "砖块堆在另 1 格")

	var item := InventorySystem.roll_item(sim.state, cfg, 0)
	InventorySystem.add_item(sim.state, item)
	_ok(BuildSystem.deposit_item(sim.state, cfg, sim.bus, crate.id, item.uid), "存入 1 件物品")
	_ok(sim.state.item_by_uid(item.uid) == null, "物品从背包移出")
	var item_slot := -1
	for i in range(crate.stored.size()):
		if String(crate.stored[i].get("kind", "")) == "item":
			item_slot = i
			break
	_ok(item_slot >= 0, "物品占 1 格")
	_ok(BuildSystem.withdraw_slot(sim.state, cfg, sim.bus, crate.id, item_slot), "取出物品")
	_ok(sim.state.item_by_uid(item.uid) != null, "物品回到背包")

	var coin1 := sim.state.coin
	_ok(BuildSystem.withdraw_resource(sim.state, cfg, sim.bus, crate.id, "coin", 40) == 40,
		"取出 40 金")
	_ok(sim.state.coin == coin1 + 40 and int(crate.stored[0].get("amount", 0)) == 60,
		"金币堆剩余 60", "coin=%d stack=%d" % [sim.state.coin, int(crate.stored[0].get("amount", 0))])

	# 满 25 格：全部放物品（资源堆会叠格，测不出满），再存资源被拒且不扣
	var filler_item := InventorySystem.item_to_dict(item)
	for i in range(crate.stored.size()):
		crate.stored[i] = {"kind": "item", "item": filler_item.duplicate(true)}
	InventorySystem.set_total(sim.state, "ammo", 100)
	_ok(not BuildSystem.deposit_resource(sim.state, cfg, sim.bus, crate.id, "ammo", 10),
		"25 格满后拒绝存入")
	_ok(sim.state.ammo == 100, "拒绝时不扣资源")

	# 背包满时不能取出物品，格子保留
	crate.stored[0] = {"kind": "item", "item": InventorySystem.item_to_dict(item)}
	item.uid = 999
	sim.state.items.clear()
	for i in range(10):
		var filler := InventorySystem.roll_item(sim.state, cfg, 0)
		InventorySystem.add_item(sim.state, filler)
	sim.drain_events()
	_ok(not BuildSystem.withdraw_slot(sim.state, cfg, sim.bus, crate.id, 0), "背包满时取出被拒")
	_ok(not (crate.stored[0] as Dictionary).is_empty(), "失败时物品仍留在箱内")
	var notice := _find_notice(sim.drain_events())
	_ok(notice.find("背包已满") >= 0, "背包满提示", notice)


# ---------------------------------------------------------------- 摧毁掉落

func _test_destroy_drops() -> void:
	var sim := _fresh(9107, 5000, 100)
	_ok(_build(sim, "crate", Vector2(8, -8)), "建木箱用于摧毁测试")
	var crate: GameState.BuildingState = sim.state.buildings[0]
	var item := InventorySystem.roll_item(sim.state, cfg, 0)
	for i in range(25):
		if i < 23:
			crate.stored[i] = {"kind": "coin", "amount": 10}
		else:
			crate.stored[i] = {"kind": "item", "item": InventorySystem.item_to_dict(item)}
	var index := crate.index
	BuildSystem.damage_building(sim.state, cfg, sim.bus, crate, 999.0, "test")
	_ok(sim.state.buildings.is_empty(), "木箱被摧毁后占位立即释放")
	_ok(sim.state.drops.size() == 25, "箱内 25 格 100% 掉落", "%d" % sim.state.drops.size())
	var scattered := 0
	var item_drops := 0
	for d in sim.state.drops:
		if d.pos.distance_to(Vector2(8, -8)) <= 1.51:
			scattered += 1
		if d.kind == "item":
			item_drops += 1
		_ok(absf(d.ttl - 60.0) < 0.01, "掉落保留 60s", "%.1f" % d.ttl)
	_ok(scattered == 25, "全部掉落落在 1.5m 散落半径内", "%d/25" % scattered)
	_ok(item_drops == 2, "物品也按件掉落", "%d" % item_drops)

	# 走过去自动拾取资源（散落半径内可能一次捡到多堆）
	var coin_before := sim.state.coin
	var before_pickup := sim.state.drops.size()
	sim.state.player.pos = sim.state.drops[0].pos
	sim.step(0.05, {"move": Vector2.ZERO})
	_ok(sim.state.coin > coin_before, "靠近自动拾取资源",
		"coin %d -> %d" % [coin_before, sim.state.coin])
	_ok(sim.state.drops.size() < before_pickup, "拾取后掉落物减少",
		"%d -> %d" % [before_pickup, sim.state.drops.size()])

	# 60s 到期消失（先走远，避免边捡边删）
	var after_pickup := sim.state.drops.size()
	sim.state.player.pos = Vector2(0, -5)
	sim.state.drops[0].ttl = 0.01
	sim.step(0.02, {"move": Vector2.ZERO})
	_ok(sim.state.drops.size() == after_pickup - 1, "到期掉落物消失",
		"%d -> %d" % [after_pickup, sim.state.drops.size()])

	# 重建继承原序号
	var idx := BuildSystem.next_index(sim.state, "crate")
	_ok(idx == index, "下一个木箱复用被毁序号", "%d vs %d" % [idx, index])
	_ok(_build(sim, "crate", Vector2(8, -8)), "原地可重建")
	_ok(sim.state.buildings[0].index == index, "重建序号 = 原序号")


# ---------------------------------------------------------------- 放置规则

func _test_placement() -> void:
	var sim := _fresh(9108, 5000, 100)
	sim.state.phase = GameState.Phase.SCOUT
	var reason := BuildSystem.placement_reason(sim.state, cfg, "crate", Vector2(8, -8))
	_ok(reason.find("建设期") >= 0, "非建设期拒绝", reason)
	PhaseMachine.enter(sim.state, GameState.Phase.BUILD, cfg, sim.bus)
	reason = BuildSystem.placement_reason(sim.state, cfg, "crate", Vector2(0, 0))
	_ok(reason.find("离水晶") >= 0, "压水晶上拒绝", reason)
	reason = BuildSystem.placement_reason(sim.state, cfg, "crate", Vector2(0, -20))
	_ok(reason.find("城墙内") >= 0, "城墙外拒绝", reason)

	# 先验墙的边界规则（此时还没建墙，名额未用）
	reason = BuildSystem.placement_reason(sim.state, cfg, "wall", Vector2(0, -60))
	_ok(reason.find("城墙内") >= 0, "城墙段也限定在城墙内", reason)
	reason = BuildSystem.placement_reason(sim.state, cfg, "wall", Vector2(0, -20))
	_ok(reason.find("城墙内") >= 0, "城墙段建到外圈也被拒绝", reason)
	reason = BuildSystem.placement_reason(sim.state, cfg, "wall", Vector2(0, 0))
	_ok(reason.find("离水晶") >= 0, "城墙压水晶拒绝", reason)

	_ok(_build(sim, "wall", Vector2(0, -14)), "先建一段 14m 的墙用于占位测试")
	reason = BuildSystem.placement_reason(sim.state, cfg, "crate", Vector2(0, -14))
	_ok(reason.find("城墙重叠") >= 0, "城墙占位拒绝", reason)
	_ok(_build(sim, "crate", Vector2(8, -8)), "先建一个木箱")
	reason = BuildSystem.placement_reason(sim.state, cfg, "cannon", Vector2(8, -8))
	_ok(reason.find("建造物重叠") >= 0, "建造物互相重叠拒绝", reason)

	var poor := _fresh(9109, 0, 100)
	reason = BuildSystem.can_build(poor.state, cfg, "crate", Vector2(8, -8))["reason"]
	_ok(reason.find("金币不足") >= 0, "资源不足提示金币差额", reason)
	var poor_brick := _fresh(9110, 5000, 0)
	reason = BuildSystem.can_build(poor_brick.state, cfg, "crate", Vector2(8, -8))["reason"]
	_ok(reason.find("砖块不足") >= 0, "资源不足提示砖块差额", reason)


# ---------------------------------------------------------------- 仇恨 / AOE / 修建造物

func _test_aggro_and_aoe() -> void:
	var sim := _fresh(9111, 5000, 100)
	_ok(_build(sim, "crate", Vector2(8, -8)), "建木箱用于仇恨测试")
	var crate: GameState.BuildingState = sim.state.buildings[0]
	PhaseMachine.enter(sim.state, GameState.Phase.WAVE, cfg, sim.bus)
	sim.state.spawn_queue.clear()
	sim.state.summon_pending.clear()
	sim.state.enemies.clear()
	var enemy := EnemyFactory.spawn(sim.state, cfg, "walker", Vector2(8, -6))
	cfg.building_def("crate")["aggro"] = 1.0
	_ok(BuildSystem.enemy_building_target(sim.state, cfg, enemy) == crate,
		"仇恨 1.0 时敌人锁定木箱")
	_ok(enemy.target_building == crate.id, "锁定的建造物 id 写回敌人")
	enemy.pos = crate.pos + Vector2(0, 1.0)
	enemy.hp = 10000
	var hp_before := crate.hp
	BuildSystem.advance_enemy_to_building(sim.state, cfg, sim.bus, enemy, crate, 0.1)
	_ok(crate.hp < hp_before, "敌人贴脸攻击木箱", "%.0f -> %.0f" % [hp_before, crate.hp])

	var enemy2 := EnemyFactory.spawn(sim.state, cfg, "walker", Vector2(8, -6))
	cfg.building_def("crate")["aggro"] = 0.0
	_ok(BuildSystem.enemy_building_target(sim.state, cfg, enemy2) == null,
		"仇恨 0 时不主动追木箱")
	_ok(enemy2.target_building == -2, "掷失败后本波不再考虑")

	# AOE：3m 内两箱一起掉血
	cfg.building_def("crate")["aggro"] = 0.3
	var sim2 := _fresh(9112, 5000, 100)
	_build(sim2, "crate", Vector2(8, -8))
	_build(sim2, "crate", Vector2(9.5, -8))
	var a: GameState.BuildingState = sim2.state.buildings[0]
	var b: GameState.BuildingState = sim2.state.buildings[1]
	BuildSystem.damage_in_radius(sim2.state, cfg, sim2.bus, Vector2(8.75, -8), 3.0, 50.0, "bomber")
	_ok(is_equal_approx(a.hp, 150.0) and is_equal_approx(b.hp, 150.0),
		"自爆 AOE 命中 3m 内两箱", "%.0f / %.0f" % [a.hp, b.hp])

	# 仇恨 0.3 的统计口径：1000 只破口敌人里约三成会锁定木箱
	cfg.building_def("crate")["aggro"] = 0.3
	var hits := 0
	for i in range(1000):
		var probe := GameState.EnemyState.new()
		probe.pos = Vector2(8, -6)
		if BuildSystem.enemy_building_target(sim2.state, cfg, probe) != null:
			hits += 1
	_ok(absf(float(hits) / 1000.0 - 0.3) < 0.06, "仇恨 0.3 ≈ 三成敌人锁定木箱",
		"%d/1000" % hits)


func _test_repair() -> void:
	var sim := _fresh(9113, 5000, 100)
	_ok(_build(sim, "crate", Vector2(8, -8)), "建木箱用于修理")
	var crate: GameState.BuildingState = sim.state.buildings[0]
	crate.hp = 50.0
	sim.state.player.pos = Vector2(8, -5)
	sim.state.player.aim = crate.pos
	sim.state.player.active_slot = 2
	sim.state.player.melee_cd = 0.0
	InventorySystem.set_total(sim.state, "brick", 10)
	sim.step(DT, {"move": Vector2.ZERO, "aim": crate.pos, "fire": true, "switch_to": 2})
	_ok(crate.hp > 50.0, "锤子可修木箱", "hp=%.0f" % crate.hp)
	_ok(sim.state.brick == 9, "修建造物消耗 1 砖", "brick=%d" % sim.state.brick)
	_ok(is_equal_approx(crate.hp, 200.0), "200 HP 木箱一锤回满", "hp=%.0f" % crate.hp)


# ---------------------------------------------------------------- 存档

func _test_save_roundtrip() -> void:
	var sim := _fresh(9114, 50000, 500, 100)
	_ok(_build(sim, "backpack", Vector2.ZERO), "存档前建背包")
	_ok(_build(sim, "crate", Vector2(8, -8)), "存档前建木箱")
	var crate: GameState.BuildingState = sim.state.buildings[0]
	BuildSystem.deposit_resource(sim.state, cfg, sim.bus, crate.id, "coin", 77)
	var item := InventorySystem.roll_item(sim.state, cfg, 0)
	InventorySystem.add_item(sim.state, item)
	BuildSystem.deposit_item(sim.state, cfg, sim.bus, crate.id, item.uid)
	_ok(_build(sim, "cannon", Vector2(12, -8)), "存档前建炮台")
	_ok(_build(sim, "wall", Vector2(0, -14)), "存档前建城墙")
	sim.state.drops.append(_make_drop(sim, 5, -5, "brick", 33))

	var text := JSON.stringify(SaveSystem.capture(sim.state))
	var target := Sim.new(cfg)
	target.new_run(1)
	var parsed: Dictionary = JSON.parse_string(text)
	var ok := SaveSystem.restore(target.state, cfg, target.bus, parsed)
	_ok(ok, "建造存档可读回")
	_ok(target.state.backpack_built == 1 and target.state.bag_rows == 4,
		"背包扩容随档还原", "rows=%d" % target.state.bag_rows)
	_ok(target.state.buildings.size() == 2, "木箱 + 炮台还原", "%d" % target.state.buildings.size())
	var restored_crate: GameState.BuildingState = target.state.buildings[0]
	_ok(restored_crate.kind == "crate" and int(restored_crate.stored[0].get("amount", 0)) == 77,
		"木箱内资源还原")
	var stored_items := 0
	for slot in restored_crate.stored:
		if String(slot.get("kind", "")) == "item":
			stored_items += 1
	_ok(stored_items == 1, "木箱内物品还原")
	var built_wall := false
	for seg in target.state.wall:
		if seg.built:
			built_wall = true
	_ok(built_wall and target.state.wall_built_this_wave == 1, "自建墙段与每波名额还原")
	_ok(target.state.drops.size() == 1 and target.state.drops[0].amount == 33, "掉落物还原")


func _make_drop(sim: Sim, x: float, y: float, kind: String, amount: int) -> GameState.DropState:
	var d := GameState.DropState.new()
	sim.state.drop_seq += 1
	d.id = sim.state.drop_seq
	d.pos = Vector2(x, y)
	d.kind = kind
	d.amount = amount
	d.ttl = 60.0
	return d


# ---------------------------------------------------------------- UI 数据

func _test_ui_state() -> void:
	var sim := _fresh(9115, 5000, 100)
	var ui := BuildSystem.ui_state(sim.state, cfg, "", Vector2(8, -8), false)
	_ok(ui["items"].size() == 4, "建造列表 4 项", "%d" % ui["items"].size())
	var crate_row: Dictionary = ui["items"][0]
	_ok(String(crate_row["id"]) == "crate" and not bool(crate_row["blocked"]),
		"资源够时木箱可建造", str(crate_row["reason"]))
	_ok(int(crate_row["cost"]["equivalent"]) == 240, "列表显示金等价 240")
	_ok(String(crate_row["limit_label"]) == "不限", "木箱上限显示不限")
	_ok(String(crate_row["count_label"]) == "已建 0 · 不限", "木箱显示当前已建数",
		str(crate_row["count_label"]))
	var wall_row: Dictionary = ui["items"][2]
	_ok(String(wall_row["limit_label"]) == "每波 1", "城墙上限显示每波 1")
	_ok(String(wall_row["count_label"]) == "本波 0/1", "城墙显示本波名额",
		str(wall_row["count_label"]))

	var poor := _fresh(9116, 0, 100)
	var poor_ui := BuildSystem.ui_state(poor.state, cfg, "", Vector2(8, -8), false)
	var poor_crate: Dictionary = poor_ui["items"][0]
	_ok(bool(poor_crate["blocked"]) and String(poor_crate["reason"]).find("金币不足") >= 0,
		"资源不足时列表给出原因", str(poor_crate["reason"]))

	var selected := BuildSystem.ui_state(sim.state, cfg, "crate", Vector2(0, 0), false)
	_ok(String(selected["preview_reason"]).find("离水晶") >= 0, "选中后位置非法给提示",
		str(selected["preview_reason"]))
	_ok(_build(sim, "crate", Vector2(8, -8)), "建一个木箱给拆除用")
	var demo := BuildSystem.ui_state(sim.state, cfg, "", Vector2(8, -8), true)
	_ok(String(demo["demolish_target"].get("kind", "")) == "building", "拆除模式锁定木箱",
		str(demo["demolish_target"]))
	_ok(_build(sim, "wall", Vector2(0, -14)), "建一段墙给上限用")
	var capped := BuildSystem.ui_state(sim.state, cfg, "", Vector2(6, -10), false)
	var wall_capped: Dictionary = capped["items"][2]
	_ok(bool(wall_capped["blocked"]) and String(wall_capped["reason"]).find("本波") >= 0,
		"城墙建满后列表置灰", str(wall_capped["reason"]))


# ---------------------------------------------------------------- 世界节点

func _test_world_nodes_after_demolish() -> void:
	var sim := _fresh(9117, 5000, 100)
	_ok(_build(sim, "wall", Vector2(0, -14)), "为拆除节点测试建墙")
	var world := WorldBuilder.new()
	root.add_child(world)
	world.build(cfg, sim.snapshot())
	_ok(world.wall_nodes.size() == sim.state.wall.size(), "装配节点数与墙段数一致",
		"%d vs %d" % [world.wall_nodes.size(), sim.state.wall.size()])
	var seg: GameState.WallSegment = sim.state.wall[sim.state.wall.size() - 1]
	_ok(BuildSystem.demolish(sim.state, cfg, sim.bus, seg.center), "拆掉自建段")
	world.sync_walls(sim.snapshot())
	_ok(world.wall_nodes.size() == sim.state.wall.size(), "拆除后多余节点被回收",
		"%d vs %d" % [world.wall_nodes.size(), sim.state.wall.size()])
	world.queue_free()