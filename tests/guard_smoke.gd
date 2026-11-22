extends SceneTree
## P1-1 / P1-2 无头断言：守卫系统与精良箱驻守。
## 只跑 core 层，不加载场景；失败会打印具体断言名并以非 0 退出。

const DT := 1.0 / 30.0

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
	_test_guard_refresh()
	_test_guard_refill_after_wave()
	_test_guard_kills_intruder()
	_test_guarded_box()

	print("CHECKS %d, FAILURES %d" % [checks, failures])
	print("GUARD_SMOKE %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 2)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _test_config() -> void:
	var row := sim.cfg.guard_row("default")
	_ok(not row.is_empty(), "guards.tsv 已加载")
	_ok(float(row.get("hp", 0)) == 480.0, "守卫 HP = 480", str(row.get("hp")))
	_ok(float(row.get("dmg", 0)) == 16.0, "守卫攻击 = 16", str(row.get("dmg")))


func _test_guard_refresh() -> void:
	sim.new_run(12345)
	sim.request("start_run")
	_fast_forward_to(GameState.Phase.BUILD, 4000)
	var capacity := int(sim.cfg.crystal_row(sim.state.crystal_level).get("guard_count", 1))
	_ok(sim.state.guard_capacity == capacity, "build 期满编人数来自 crystal_levels", str(sim.state.guard_capacity))
	_ok(sim.state.guards_alive().size() == capacity, "build 期守卫数量等于满编", str(sim.state.guards_alive().size()))
	var g: GameState.GuardState = sim.state.guards[0]
	_ok(is_equal_approx(g.hp, g.max_hp), "补满后满血")
	_ok(g.pos.distance_to(g.station) < 0.01, "补满后复位到站位")

	# 水晶升级后再次进入 build，应当补到新人数
	InventorySystem.set_total(sim.state, "coin", 5000)
	InventorySystem.set_total(sim.state, "metal", 500)
	EconomySystem.upgrade_crystal(sim.state, sim.cfg, sim.bus)
	GuardSystem.refresh(sim.state, sim.cfg, sim.bus)
	_ok(sim.state.guards_alive().size() == 2, "水晶 Lv2 后守卫补到 2", str(sim.state.guards_alive().size()))


func _test_guard_refill_after_wave() -> void:
	# 波内击杀一名守卫，确认本波不复活；结束后 build 补满
	sim.request("start_wave")
	_ok(sim.state.phase == GameState.Phase.WAVE, "已进入 WAVE")
	var guard: GameState.GuardState = sim.state.guards[0]
	guard.hp = 0.0
	guard.alive = false
	for i in range(30):
		GuardSystem.step(sim.state, DT, sim.cfg, sim.bus)
	_ok(sim.state.guards_alive().size() == 1, "波内死亡不复活", str(sim.state.guards_alive().size()))

	sim.state.phase = GameState.Phase.BUILD
	GuardSystem.refresh(sim.state, sim.cfg, sim.bus)
	_ok(sim.state.guards_alive().size() == 2, "build 期补满到 2", str(sim.state.guards_alive().size()))
	_ok(is_equal_approx(sim.state.guards[0].hp, sim.state.guards[0].max_hp), "补满的守卫满血")


func _test_guard_kills_intruder() -> void:
	sim.state.phase = GameState.Phase.WAVE
	sim.state.enemies.clear()
	var guard: GameState.GuardState = sim.state.guards[0]
	var intruder := EnemyFactory.spawn(sim.state, sim.cfg, "walker", guard.pos + Vector2(3.0, 0.0))
	var hp_before := intruder.hp
	for i in range(int(12.0 / DT)):
		GuardSystem.step(sim.state, DT, sim.cfg, sim.bus)
		if not intruder.alive:
			break
	_ok(not intruder.alive, "守卫能独立击杀城内 walker", "hp %.1f -> %.1f" % [hp_before, intruder.hp])
	_ok(guard.alive, "守卫在 1v1 中存活")


func _test_guarded_box() -> void:
	sim.new_run(777)
	sim.request("start_run")
	_ok(sim.state.phase == GameState.Phase.SCOUT, "已进入 SCOUT")
	var refined: Dictionary = {}
	for box in sim.state.loot_boxes:
		if String(box["tier"]) == "refined":
			refined = box
			break
	_ok(not refined.is_empty(), "存在精良箱")
	if refined.is_empty():
		return
	var guard_ids: Array = refined["guard_ids"]
	_ok(guard_ids.size() >= 2 and guard_ids.size() <= 4, "精良箱驻守 2–4 只", str(guard_ids.size()))

	sim.state.player.pos = refined["pos"]
	for i in range(10):
		sim.step(DT, {})
	_ok(not bool(refined["opened"]), "驻守未清空时箱子不可开启")

	for id in guard_ids:
		var e := sim.state.enemy_by_id(int(id))
		if e != null:
			e.alive = false
	# 清掉追兵，避免扫描途中被打死回城导致中断（这不是本用例要测的东西）
	for e in sim.state.enemies:
		e.alive = false
	# 搜索式开箱（2026-11-09）：清空驻守后还要扫 4×4 网格才开完
	var opened := false
	for i in range(int(6.0 / DT)):
		sim.step(DT, {})
		sim.drain_events()
		if bool(refined["opened"]):
			opened = true
			break
	_ok(opened, "驻守清空后靠近开始搜索并开完")


func _fast_forward_to(phase: int, max_steps: int) -> void:
	for i in range(max_steps):
		if sim.state.phase == phase:
			return
		sim.step(DT, {})
		sim.drain_events()
