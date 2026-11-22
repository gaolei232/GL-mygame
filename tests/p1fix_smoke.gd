extends SceneTree
## P1 修复回归：射程 / 冲刺 / 敌人打墙优先 / 单次点击开火 / 城墙结算 / 开箱事件。

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

	_test_range()
	_test_sprint()
	_test_wave_targets_wall()
	_test_single_click_fires_once()
	_test_wall_damage_settles()
	_test_loot_event()
	_test_restart_resets()
	_test_wall_upgrade()

	print("CHECKS %d, FAILURES %d" % [checks, failures])
	print("P1FIX_SMOKE %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 2)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _start_scout(seed_value: int = 2026) -> void:
	sim.new_run(seed_value)
	sim.request("start_run")
	sim.state.enemies.clear()


# 1) 射程
func _test_range() -> void:
	var reach := float(sim.cfg.balance["weapons"]["crossbow"]["range"])
	_ok(reach >= 30.0, "弩有效射程 ≥ 30m", "range=%.1f" % reach)

	_start_scout()
	var origin := Vector2(6.0, 0.0)                 # 射向 -z，射线不穿过水晶
	var target_pos := origin + Vector2(0, -(reach - 2.0))
	var enemy := EnemyFactory.spawn(sim.state, sim.cfg, "walker", target_pos)
	var hit := Combat.resolve_shot(sim.state, origin, Vector2(0, -1), reach)
	_ok(hit["kind"] == "enemy" and hit["enemy"] == enemy, "30m 外目标可被命中",
		"kind=%s dist=%.1f" % [hit["kind"], float(hit["dist"])])


# 2) 冲刺
func _test_sprint() -> void:
	_start_scout()
	var walk := _measure({})
	_start_scout()
	var sprint := _measure({"sprint": true})
	_start_scout()
	var sprint_focus := _measure({"sprint": true, "focus_aim": true})
	_start_scout()
	var focus := _measure({"focus_aim": true})
	var ratio := sprint / maxf(0.001, walk)
	_ok(ratio > 1.9 and ratio < 2.1, "Shift 冲刺移速 ×2.0", "ratio=%.2f" % ratio)
	_ok(is_equal_approx(sprint_focus, focus), "瞄准时冲刺被屏蔽",
		"sprint+focus=%.3f focus=%.3f" % [sprint_focus, focus])


func _measure(extra: Dictionary) -> float:
	sim.state.player.pos = Vector2(0, 0)
	for i in range(30):
		var cmd := {"move": Vector2.UP, "aim": Vector2.UP, "fire": false, "switch_to": -1}
		cmd.merge(extra, true)
		sim.step(DT, cmd)
	var moved: float = sim.state.player.pos.length()
	sim.state.player.pos = Vector2(0, 0)
	return moved


# 3) 战斗期墙外敌人只拆墙，不打玩家
func _test_wave_targets_wall() -> void:
	sim.new_run(2027)
	sim.request("start_run")
	PhaseMachine.enter(sim.state, GameState.Phase.BUILD, sim.cfg, sim.bus)
	PhaseMachine.enter(sim.state, GameState.Phase.WAVE, sim.cfg, sim.bus)
	sim.state.spawn_queue.clear()
	sim.state.enemies.clear()

	var seg: GameState.WallSegment = sim.state.wall[3]
	var outside: Vector2 = seg.center + seg.center.normalized() * 1.2      # 墙外贴墙
	sim.state.player.pos = outside + Vector2(0.6, 0)              # 玩家贴着同一位置（墙外）
	var enemy: GameState.EnemyState = EnemyFactory.spawn(sim.state, sim.cfg, "walker", outside)
	var hp_before: float = seg.hp
	var player_hp: float = sim.state.player.hp
	for i in range(int(6.0 / DT)):
		sim.step(DT, {"move": Vector2.ZERO, "aim": Vector2.UP, "fire": false, "switch_to": -1})
		sim.drain_events()
	_ok(seg.hp < hp_before, "战斗期敌人正常拆墙", "%.0f -> %.0f" % [hp_before, seg.hp])
	_ok(is_equal_approx(sim.state.player.hp, player_hp), "墙外敌人不再直接打玩家",
		"player %.1f -> %.1f" % [player_hp, sim.state.player.hp])
	_ok(enemy.alive, "测试敌人存活（未被守卫秒杀）")


# 4) 单次点击只开一枪（模拟“按下即松开”的短点击）
func _test_single_click_fires_once() -> void:
	_start_scout()
	InventorySystem.set_total(sim.state, "ammo", 50)
	var ammo_before := sim.state.ammo
	var enemy := EnemyFactory.spawn(sim.state, sim.cfg, "walker", Vector2(0, -8))
	sim.state.player.pos = Vector2(0, 0)
	var cmd := {"move": Vector2.ZERO, "aim": enemy.pos, "fire": true, "switch_to": -1}
	sim.step(DT, cmd)
	var after_click := sim.state.ammo
	_ok(after_click == ammo_before - 1, "一次开火请求只消耗 1 发", "ammo %d -> %d" % [ammo_before, after_click])
	# 冷却期内继续按住也不该连发
	for i in range(10):
		sim.step(DT, cmd)
	_ok(sim.state.ammo >= after_click - 1, "冷却期内不会瞬发多发", "ammo=%d" % sim.state.ammo)


# 5) 城墙伤害结算
func _test_wall_damage_settles() -> void:
	sim.new_run(2028)
	sim.request("start_run")
	PhaseMachine.enter(sim.state, GameState.Phase.BUILD, sim.cfg, sim.bus)
	PhaseMachine.enter(sim.state, GameState.Phase.WAVE, sim.cfg, sim.bus)
	sim.state.player.pos = Vector2(0, 40)          # 玩家远离
	var total := 0.0
	for seg in sim.state.wall:
		total += seg.hp
	for i in range(int(20.0 / DT)):
		sim.step(DT, {"move": Vector2.ZERO, "aim": Vector2.UP, "fire": false, "switch_to": -1})
		sim.drain_events()
	var after := 0.0
	for seg in sim.state.wall:
		after += seg.hp
	_ok(after < total, "第 1 波 20 秒内城墙持续受损", "%.0f -> %.0f (delta %.0f)" % [total, after, total - after])


# 6) 开箱事件带收益明细（供 HUD 提示）
func _test_loot_event() -> void:
	_start_scout(3031)
	var box: Dictionary = {}
	for b in sim.state.loot_boxes:
		if String(b["tier"]) == "common":
			box = b
			break
	_ok(not box.is_empty(), "存在普通箱")
	sim.state.player.pos = box["pos"]
	for e in sim.state.enemies:
		e.alive = false          # 追兵会打断扫描，这不是本用例要测的
	var found := false
	var gain_seen := {}
	# 搜索式开箱（2026-11-09）：站定扫完 4×4 网格才发 LOOT_OPENED
	for i in range(int(8.0 / DT)):
		sim.step(DT, {"move": Vector2.ZERO, "aim": Vector2.UP, "fire": false, "switch_to": -1})
		for ev in sim.drain_events():
			if String(ev["type"]) == EventBus.LOOT_OPENED:
				var gain: Dictionary = ev["data"].get("gain", {})
				gain_seen = gain
				found = gain.has("coin") and gain.has("brick") and gain.has("ammo")
		if found:
			break
	_ok(found, "开箱事件包含 coin/brick/ammo 收益明细", str(gain_seen))


# 7) 重开一局必须清零本局统计与主题（R-6，2026-11-09）
func _test_restart_resets() -> void:
	_start_scout(4041)
	sim.state.stats["kills"] = 7
	sim.state.stats["deaths"] = 3
	sim.state.theme = "fire"
	sim.new_run(4042)
	_ok(int(sim.state.stats["kills"]) == 0 and int(sim.state.stats["deaths"]) == 0,
		"重开清零击杀/死亡", "kills=%d deaths=%d" % [int(sim.state.stats["kills"]), int(sim.state.stats["deaths"])])
	_ok(sim.state.theme == "", "重开清空主题", "theme=%s" % sim.state.theme)

	# 死亡/复活残留也必须清：否则重开会以 alive=false 开场（2026-11-09 守卫用例暴露）
	sim.state.player.alive = false
	sim.state.player.respawn_timer = 5.0
	sim.new_run(4043)
	_ok(sim.state.player.alive and is_zero_approx(sim.state.player.respawn_timer),
		"重开清掉死亡/复活残留", "alive=%s timer=%.1f" % [str(sim.state.player.alive), sim.state.player.respawn_timer])


# 8) 墙段升级（P0-7）：只有建设期可升级；扣 20 砖 + 80 金；等级 +1、上限 ×1.35 且回满
func _test_wall_upgrade() -> void:
	_start_scout(5051)
	var coin0 := sim.state.coin
	_ok(not EconomySystem.upgrade_wall(sim.state, sim.cfg, sim.bus, 0) and sim.state.coin == coin0,
		"搜集期不能升级城墙", "coin %d -> %d" % [coin0, sim.state.coin])

	sim.new_run(5052)
	PhaseMachine.enter(sim.state, GameState.Phase.BUILD, sim.cfg, sim.bus)
	InventorySystem.set_total(sim.state, "coin", 500)
	InventorySystem.set_total(sim.state, "brick", 100)
	var seg: GameState.WallSegment = sim.state.wall[0]
	seg.hp = seg.max_hp * 0.4
	var max0 := seg.max_hp
	var ok := EconomySystem.upgrade_wall(sim.state, sim.cfg, sim.bus, 0)
	_ok(ok and seg.level == 2, "建设期升级到 Lv2", "level=%d" % seg.level)
	_ok(is_equal_approx(seg.max_hp, max0 * 1.35) and is_equal_approx(seg.hp, seg.max_hp),
		"升级后上限 ×1.35 并回满", "max %.0f -> %.0f hp %.0f" % [max0, seg.max_hp, seg.hp])
	_ok(sim.state.coin == 500 - 80 and sim.state.brick == 100 - 20, "升级扣 20 砖 + 80 金",
		"coin=%d brick=%d" % [sim.state.coin, sim.state.brick])

	# 光标命中（wall_segment_at）：段中心命中该段，城内中心不命中
	var target: GameState.WallSegment = sim.state.wall[3]
	_ok(sim.state.wall_segment_at(target.center, 2.0) == 3, "光标落在段中心命中该段",
		"idx=%d" % sim.state.wall_segment_at(target.center, 2.0))
	_ok(sim.state.wall_segment_at(Vector2.ZERO, 2.0) == -1, "城内中心不命中任何墙段")
