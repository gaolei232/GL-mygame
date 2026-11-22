extends SceneTree
## P0-9 存档：JSON 往返还原字段、非法存档拒绝、三个阶段各自可读。

var cfg: ConfigDB
var checks := 0
var failures := 0


func _init() -> void:
	cfg = ConfigDB.new()
	if not cfg.load_all():
		printerr("配置加载失败：", cfg.errors)
		quit(1)
		return

	_test_build_roundtrip()
	_test_reject_invalid()
	_test_scout_restore()
	_test_reward_restore()

	print("CHECKS %d, FAILURES %d" % [checks, failures])
	print("SAVE_SMOKE %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 2)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


## 走一遍真实 JSON 字符串，而不是直接传字典——类型（int/float/bool/null）的问题只在字符串里暴露
func _roundtrip(sim: Sim) -> Dictionary:
	var text := JSON.stringify(SaveSystem.capture(sim.state))
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}


func _test_build_roundtrip() -> void:
	var sim := Sim.new(cfg)
	sim.new_run(777)
	sim.request("start_run")
	sim.request("return_city")                 # SCOUT → BUILD
	var s := sim.state
	InventorySystem.set_total(s, "coin", 1234)
	InventorySystem.set_total(s, "brick", 77)
	InventorySystem.set_total(s, "metal", 9)
	InventorySystem.set_total(s, "ammo", 42)
	s.wave_index = 3
	s.crystal_hp = 321.0
	s.wall[2].hp = 500.0
	s.wall[2].level = 2
	s.wall[5].breached = true
	s.wall[5].hp = 0.0
	s.player.pos = Vector2(3.5, -7.25)
	s.player.hp = 61.0
	s.player.weapon_levels["crossbow"] = 4
	s.theme = "fire"
	s.stats["kills"] = 17
	var item := InventorySystem.roll_item(s, cfg)
	InventorySystem.add_item(s, item)
	InventorySystem.equip(s, cfg, item.uid)

	var data := _roundtrip(sim)
	var target := Sim.new(cfg)
	target.new_run(1)
	target.state.enemies.append(EnemyFactory.spawn(target.state, cfg, "walker", Vector2(9, 9)))  # 模拟同进程残留
	var ok := SaveSystem.restore(target.state, cfg, target.bus, data)
	var t := target.state
	_ok(ok, "建设期存档读入成功")
	_ok(t.phase == GameState.Phase.BUILD, "阶段 = 建设期", "phase=%s" % GameState.phase_name(t.phase))
	_ok(t.coin == 1234 and t.brick == 77 and t.metal == 9 and t.ammo == 42,
		"四种资源还原", "coin=%d brick=%d metal=%d ammo=%d" % [t.coin, t.brick, t.metal, t.ammo])
	_ok(t.wave_index == 3, "波次还原", "wave=%d" % t.wave_index)
	_ok(is_equal_approx(t.crystal_hp, 321.0), "水晶血量还原", "%.0f" % t.crystal_hp)
	_ok(is_equal_approx(t.wall[2].hp, 500.0) and t.wall[2].level == 2,
		"墙段血量与等级还原", "hp=%.0f lv=%d" % [t.wall[2].hp, t.wall[2].level])
	_ok(t.wall[5].breached, "破口状态还原")
	_ok(t.player.pos.distance_to(Vector2(3.5, -7.25)) < 0.01, "玩家位置还原",
		"%s" % str(t.player.pos))
	_ok(is_equal_approx(t.player.hp, 61.0), "玩家血量还原", "%.0f" % t.player.hp)
	_ok(int(t.player.weapon_levels["crossbow"]) == 4, "武器等级还原")
	_ok(t.theme == "fire", "主题还原", t.theme)
	_ok(int(t.stats["kills"]) == 17, "击杀统计还原", "kills=%d" % int(t.stats["kills"]))
	var gear := 0
	for it in t.items:
		if not InventorySystem.is_resource(it):
			gear += 1
	_ok(gear == 1 and t.equipped.size() == 1, "背包与装备还原（资源堆另算）",
		"gear=%d res=%d equipped=%d" % [gear, t.items.size() - gear, t.equipped.size()])
	_ok(t.enemies.is_empty(), "读档清掉残留敌人", "enemies=%d" % t.enemies.size())
	_ok(t.guards.size() > 0, "守卫按水晶等级补满", "guards=%d" % t.guards.size())


func _test_reject_invalid() -> void:
	var sim := Sim.new(cfg)
	sim.new_run(999)
	sim.request("start_run")
	var data := _roundtrip(sim)
	var target := Sim.new(cfg)
	target.new_run(2)

	var bad_phase := data.duplicate(true)
	bad_phase["phase"] = GameState.Phase.WAVE
	_ok(not SaveSystem.restore(target.state, cfg, target.bus, bad_phase), "战斗期存档被拒绝")

	var bad_version := data.duplicate(true)
	bad_version["version"] = 999
	_ok(not SaveSystem.restore(target.state, cfg, target.bus, bad_version), "版本不符被拒绝")

	var bad_wall := data.duplicate(true)
	bad_wall["wall"] = []
	_ok(not SaveSystem.restore(target.state, cfg, target.bus, bad_wall), "墙段数量不符被拒绝")


func _test_scout_restore() -> void:
	var sim := Sim.new(cfg)
	sim.new_run(555)
	sim.request("start_run")                   # SCOUT
	var target := Sim.new(cfg)
	target.new_run(3)
	_ok(SaveSystem.restore(target.state, cfg, target.bus, _roundtrip(sim)), "搜集期存档读入成功")
	_ok(target.state.phase == GameState.Phase.SCOUT and target.state.loot_boxes.size() > 0,
		"搜集期箱子按规则重新生成", "boxes=%d" % target.state.loot_boxes.size())
	_ok(is_equal_approx(target.state.phase_duration, 90.0), "搜集期时长恢复",
		"%.1fs" % target.state.phase_duration)


func _test_reward_restore() -> void:
	var sim := Sim.new(cfg)
	sim.new_run(888)
	sim.request("start_run")
	PhaseMachine.enter(sim.state, GameState.Phase.BUILD, cfg, sim.bus)
	PhaseMachine.enter(sim.state, GameState.Phase.WAVE, cfg, sim.bus)
	PhaseMachine.enter(sim.state, GameState.Phase.REWARD, cfg, sim.bus)
	var target := Sim.new(cfg)
	target.new_run(4)
	_ok(SaveSystem.restore(target.state, cfg, target.bus, _roundtrip(sim)), "奖励期存档读入成功")
	_ok(target.state.phase == GameState.Phase.REWARD and target.state.reward_choices.size() == 4,
		"第 1 波末的主题四选一被还原", "choices=%d" % target.state.reward_choices.size())