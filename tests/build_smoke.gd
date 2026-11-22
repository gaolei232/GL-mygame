extends SceneTree
## 建造与修理（2026-11-09 试玩反馈）：锤子修墙有反馈、按光标选段、破口重建、锤子升级。

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
	_test_repair_basic()
	_test_repair_aims()
	_test_repair_no_brick()
	_test_rebuild()
	_test_hammer_upgrade()
	_test_new_run_resets_weapons()
	print("CHECKS %d, FAILURES %d" % [checks, failures])
	print("BUILD_SMOKE %s" % ("PASS" if failures == 0 else "FAIL"))
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
	sim.drain_events()          # 丢掉开局的“出城搜集”提示，避免误判后面的 NOTICE
	return sim


## 站在墙内侧 2m，光标压在该段中心
func _stand_at(sim: Sim, index: int) -> GameState.WallSegment:
	var seg: GameState.WallSegment = sim.state.wall[index]
	sim.state.player.pos = seg.center - seg.center.normalized() * 2.0
	sim.state.player.aim = seg.center
	sim.state.player.active_slot = 2
	sim.state.player.melee_cd = 0.0
	return seg


func _swing(sim: Sim) -> Array:
	sim.step(DT, {"move": Vector2.ZERO, "aim": sim.state.player.aim, "fire": true, "switch_to": 2})
	return sim.drain_events()


func _find(events: Array, type: String) -> Dictionary:
	for e in events:
		if String(e["type"]) == type:
			return e["data"]
	return {}


func _test_repair_basic() -> void:
	var sim := _fresh_build(6001)
	var seg := _stand_at(sim, 3)
	seg.hp = seg.max_hp - 5000.0
	InventorySystem.set_total(sim.state, "brick", 10)
	var before := seg.hp
	var ev := _swing(sim)
	var healed := _find(ev, EventBus.WALL_REPAIRED)
	_ok(seg.hp > before, "锤子修墙真的加血（原本完全没有反馈）",
		"%.0f -> %.0f" % [before, seg.hp])
	_ok(sim.state.brick == 9, "修墙消耗 1 砖", "brick=%d" % sim.state.brick)
	_ok(not healed.is_empty() and int(round(float(healed.get("heal", 0.0)))) > 0,
		"WALL_REPAIRED 带实际回复量（供飘字）", str(healed))
	_ok(float(healed.get("heal", 0.0)) > 800.0, "Lv1 锤子单次约 900 HP",
		"heal=%.0f" % float(healed.get("heal", 0.0)))


func _test_repair_aims() -> void:
	var sim := _fresh_build(6002)
	var near := _stand_at(sim, 3)
	near.hp = near.max_hp - 5000.0
	# 让 3 号满血、4 号带伤：光标压在 3 号上，应该自动改修「身边有伤的」而不是白扔砖
	near.hp = near.max_hp
	var other: GameState.WallSegment = sim.state.wall[4]
	other.hp = other.max_hp - 5000.0
	sim.state.player.pos = (near.center + other.center) * 0.5
	sim.state.player.pos -= sim.state.player.pos.normalized() * 1.0
	InventorySystem.set_total(sim.state, "brick", 10)
	var before := other.hp
	_swing(sim)
	_ok(other.hp > before, "光标段满血时改修身边有损伤的段", "%.0f -> %.0f" % [before, other.hp])
	_ok(sim.state.brick < 10, "这种情况下砖仍然被消耗（确实修了东西）", "brick=%d" % sim.state.brick)


func _test_repair_no_brick() -> void:
	var sim := _fresh_build(6003)
	var seg := _stand_at(sim, 3)
	seg.hp = seg.max_hp - 5000.0
	InventorySystem.set_total(sim.state, "brick", 0)
	var before := seg.hp
	var ev := _swing(sim)
	var notice := _find(ev, EventBus.NOTICE)
	_ok(is_equal_approx(seg.hp, before), "没砖不能修")
	_ok(str(notice.get("text", "")).find("砖块不足") >= 0, "提示「砖块不足」",
		str(notice.get("text", "")))


func _test_rebuild() -> void:
	var sim := _fresh_build(6004)
	var seg: GameState.WallSegment = sim.state.wall[0]
	seg.breached = true
	seg.hp = 0.0
	InventorySystem.set_total(sim.state, "brick", 100)
	InventorySystem.set_total(sim.state, "coin", 500)
	_ok(EconomySystem.rebuild_wall(sim.state, cfg, sim.bus, 0), "破口可以重建")
	_ok(not seg.breached and is_equal_approx(seg.hp, seg.max_hp), "重建后整段回满",
		"breached=%s hp=%.0f/%.0f" % [str(seg.breached), seg.hp, seg.max_hp])
	_ok(sim.state.brick == 70 and sim.state.coin == 350, "重建扣 30 砖 + 150 金",
		"brick=%d coin=%d" % [sim.state.brick, sim.state.coin])
	_ok(not EconomySystem.rebuild_wall(sim.state, cfg, sim.bus, 1), "完好段不能重建")

	var scout := Sim.new(cfg)
	scout.new_run(6005)
	scout.request("start_run")
	scout.state.wall[0].breached = true
	InventorySystem.set_total(scout.state, "brick", 999)
	InventorySystem.set_total(scout.state, "coin", 9999)
	_ok(not EconomySystem.rebuild_wall(scout.state, cfg, scout.bus, 0), "搜集期不能重建")


func _test_hammer_upgrade() -> void:
	var sim := _fresh_build(6006)
	InventorySystem.set_total(sim.state, "coin", 500)
	InventorySystem.set_total(sim.state, "metal", 50)
	_ok(EconomySystem.upgrade_weapon(sim.state, cfg, sim.bus, "hammer"), "锤子可以强化")
	_ok(int(sim.state.player.weapon_levels.get("hammer", 1)) == 2, "锤子等级 → 2")
	var seg := _stand_at(sim, 3)
	seg.hp = seg.max_hp - 5000.0
	InventorySystem.set_total(sim.state, "brick", 10)
	var ev := _swing(sim)
	var healed := _find(ev, EventBus.WALL_REPAIRED)
	_ok(float(healed.get("heal", 0.0)) > 1000.0, "Lv2 锤子单砖回复量提升（900 → 1035）",
		"heal=%.0f" % float(healed.get("heal", 0.0)))


func _test_new_run_resets_weapons() -> void:
	var sim := _fresh_build(6007)
	InventorySystem.set_total(sim.state, "coin", 999)
	InventorySystem.set_total(sim.state, "metal", 99)
	EconomySystem.upgrade_weapon(sim.state, cfg, sim.bus, "crossbow")
	sim.new_run(6008)
	_ok(int(sim.state.player.weapon_levels.get("crossbow", 99)) == 1,
		"重开一局武器等级归 1（原来会跨局残留）",
		"crossbow=%d" % int(sim.state.player.weapon_levels.get("crossbow", 99)))
	_ok(int(sim.state.player.weapon_levels.get("hammer", 99)) == 1, "锤子等级也归 1")