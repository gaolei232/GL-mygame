extends SceneTree
## 无限段城墙（2026-11-09 规则）：造价公式、建造校验、新建段可修可升级、存档带几何。

var cfg: ConfigDB
var checks := 0
var failures := 0


func _init() -> void:
	cfg = ConfigDB.new()
	if not cfg.load_all():
		printerr("配置加载失败：", cfg.errors)
		quit(1)
		return
	_test_cost_formula()
	_test_build()
	_test_build_guards()
	_test_built_segment_behaviour()
	_test_save_roundtrip()
	_test_world_nodes()
	print("CHECKS %d, FAILURES %d" % [checks, failures])
	print("WALL_BUILD_SMOKE %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 2)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _fresh_build(seed_value: int) -> Sim:
	var sim := Sim.new(cfg)
	sim.new_run(seed_value)
	sim.request("start_run")
	sim.request("return_city")
	sim.state.enemies.clear()
	sim.drain_events()
	return sim


## 每波只能新建 1 段：走一圈 REWARD → SCOUT → BUILD 重置闸门，墙段本身保留。
func _next_build_phase(sim: Sim) -> void:
	PhaseMachine.enter(sim.state, GameState.Phase.REWARD, cfg, sim.bus)
	PhaseMachine.enter(sim.state, GameState.Phase.SCOUT, cfg, sim.bus)
	sim.request("return_city")
	sim.state.enemies.clear()
	sim.drain_events()


func _test_cost_formula() -> void:
	var total := 0.0
	for row in cfg.waves:
		total += cfg.wave_max_coin(row)
	var avg := total / float(cfg.waves.size())
	var cost := cfg.wall_build_coin_cost()
	_ok(absf(float(cost) - avg * 0.5) <= 1.0, "造价 = 每波最大金币均值的 50%",
		"cost=%d avg=%.1f" % [cost, avg])
	_ok(cost > 0 and cost == int(cfg.wall_build_coin_cost()),
		"造价 = 配表推导值（%d）" % int(cfg.wall_build_coin_cost()), "cost=%d" % cost)
	_ok(cfg.scout_coin_income(1) > 60.0, "搜集期金币收入算进去了（新开箱模型，期望口径）",
		"scout_income=%.0f" % cfg.scout_coin_income(1))


func _test_build() -> void:
	var sim := _fresh_build(7101)
	InventorySystem.set_total(sim.state, "coin", 2000)
	InventorySystem.set_total(sim.state, "brick", 100)
	var before := sim.state.wall.size()
	var cost := cfg.wall_build_coin_cost()
	var pos := Vector2(0, -14)
	var ok := EconomySystem.build_wall(sim.state, cfg, sim.bus, pos)
	_ok(ok and sim.state.wall.size() == before + 1, "建设期能新建墙段",
		"walls=%d" % sim.state.wall.size())
	_ok(sim.state.coin == 2000 - cost and sim.state.brick == 80,
		"扣 %d 金 + 20 砖" % cost, "coin=%d brick=%d" % [sim.state.coin, sim.state.brick])
	var seg: GameState.WallSegment = sim.state.wall[before]
	_ok(seg.center.distance_to(pos) < 0.01 and seg.index == before, "新段位置与索引正确")
	var radial := pos.normalized()
	_ok(absf(seg.tangent.dot(radial)) < 0.01, "切向与半径垂直（和墙圈同曲率）",
		"dot=%.3f" % seg.tangent.dot(radial))
	_ok(is_equal_approx(seg.hp, seg.max_hp) and seg.level == 1, "新段满血 Lv1")


func _test_build_guards() -> void:
	var sim := _fresh_build(7102)
	InventorySystem.set_total(sim.state, "coin", 5000)
	InventorySystem.set_total(sim.state, "brick", 200)
	_ok(not EconomySystem.build_wall(sim.state, cfg, sim.bus, Vector2(0, -3)), "离水晶太近不能建")
	_ok(not EconomySystem.build_wall(sim.state, cfg, sim.bus, Vector2(0, -60)), "城墙外不能建（自由建造限定城内）")
	EconomySystem.build_wall(sim.state, cfg, sim.bus, Vector2(0, -14))
	var n := sim.state.wall.size()
	_ok(not EconomySystem.build_wall(sim.state, cfg, sim.bus, Vector2(0.3, -14.2)),
		"已有城墙的位置不能叠")
	_ok(sim.state.wall.size() == n, "被拒绝时不会多出墙段")

	var wave := _fresh_build(7103)
	PhaseMachine.enter(wave.state, GameState.Phase.WAVE, cfg, wave.bus)
	InventorySystem.set_total(wave.state, "coin", 5000)
	InventorySystem.set_total(wave.state, "brick", 200)
	_ok(not EconomySystem.build_wall(wave.state, cfg, wave.bus, Vector2(0, -14)),
		"战斗期不能新建（破口重建仍然可以）")

	var poor := _fresh_build(7104)
	InventorySystem.set_total(poor.state, "coin", 0)
	InventorySystem.set_total(poor.state, "brick", 0)
	var ev := []
	EconomySystem.build_wall(poor.state, cfg, poor.bus, Vector2(0, -14))
	ev = poor.drain_events()
	var notice := ""
	for e in ev:
		if String(e["type"]) == EventBus.NOTICE:
			notice = str(e["data"].get("text", ""))
	_ok(notice.find("不足") >= 0, "资源不足给明确提示", notice)


func _test_built_segment_behaviour() -> void:
	var sim := _fresh_build(7105)
	InventorySystem.set_total(sim.state, "coin", 5000)
	InventorySystem.set_total(sim.state, "brick", 100)
	EconomySystem.build_wall(sim.state, cfg, sim.bus, Vector2(0, -14))
	var idx := sim.state.wall.size() - 1
	var seg: GameState.WallSegment = sim.state.wall[idx]
	_ok(EconomySystem.upgrade_wall(sim.state, cfg, sim.bus, idx), "新建的墙段可以升级")
	_ok(seg.level == 2, "新段升级到 Lv2")

	# 修墙也要能找到它。建在 14m（城内）以便建设期站得到；
	# 建在 22m 的墙在建设期够不着（活动范围只到 16.5m），要等战斗期出城
	seg.hp = seg.max_hp - 4000.0
	sim.state.player.pos = seg.center - seg.center.normalized() * 2.0
	sim.state.player.aim = seg.center
	sim.state.player.active_slot = 2
	sim.state.player.melee_cd = 0.0
	InventorySystem.set_total(sim.state, "brick", 10)
	var before := seg.hp
	sim.step(1.0 / 60.0, {"move": Vector2.ZERO, "aim": seg.center, "fire": true, "switch_to": 2})
	_ok(seg.hp > before, "新建的墙段可以修", "%.0f -> %.0f" % [before, seg.hp])


func _test_save_roundtrip() -> void:
	var sim := _fresh_build(7106)
	InventorySystem.set_total(sim.state, "coin", 5000)
	InventorySystem.set_total(sim.state, "brick", 100)
	EconomySystem.build_wall(sim.state, cfg, sim.bus, Vector2(0, -14))
	_next_build_phase(sim)
	EconomySystem.build_wall(sim.state, cfg, sim.bus, Vector2(6, -10))
	var count := sim.state.wall.size()
	_ok(count == 9, "两波各造一段：共 9 段", "walls=%d" % count)
	var text := JSON.stringify(SaveSystem.capture(sim.state))
	var parsed: Dictionary = JSON.parse_string(text)
	var target := Sim.new(cfg)
	target.new_run(1)
	_ok(SaveSystem.restore(target.state, cfg, target.bus, parsed), "带自建墙段的存档能读回")
	_ok(target.state.wall.size() == count, "墙段数量保持 %d" % count,
		"restored=%d" % target.state.wall.size())
	var last: GameState.WallSegment = target.state.wall[count - 1]
	_ok(last.center.distance_to(Vector2(6, -10)) < 0.01, "自建段的位置被保存",
		"%s" % str(last.center))


func _test_world_nodes() -> void:
	var sim := _fresh_build(7107)
	InventorySystem.set_total(sim.state, "coin", 5000)
	InventorySystem.set_total(sim.state, "brick", 100)
	EconomySystem.build_wall(sim.state, cfg, sim.bus, Vector2(0, -14))
	var world := WorldBuilder.new()
	root.add_child(world)
	world.build(cfg, sim.snapshot())
	var before := world.wall_nodes.size()
	_ok(before == sim.state.wall.size(), "建墙后首次装配节点数一致",
		"nodes=%d walls=%d" % [before, sim.state.wall.size()])
	_next_build_phase(sim)
	InventorySystem.set_total(sim.state, "coin", 5000)
	InventorySystem.set_total(sim.state, "brick", 100)
	EconomySystem.build_wall(sim.state, cfg, sim.bus, Vector2(-8, -10))
	world.sync_walls(sim.snapshot())
	_ok(world.wall_nodes.size() == before + 1, "运行中新建的墙段会自动补节点（无需重建场景）",
		"nodes=%d" % world.wall_nodes.size())
	world.queue_free()