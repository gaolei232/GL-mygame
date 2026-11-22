extends SceneTree
## 2026-11-08 四项改动的回归：主菜单数据面 / 翻滚 / 随时可攻击 / 敌潮节奏。
## 主菜单是纯 UI，靠 visual_capture 截图验证；这里只测它能拿到的那部分（TITLE 阶段不开火）。

const DT := 1.0 / 60.0

var sim: Sim
var cfg: ConfigDB
var failures := 0
var checks := 0


func _init() -> void:
	cfg = ConfigDB.new()
	if not cfg.load_all():
		printerr("配置加载失败：", cfg.errors)
		quit(1)
		return
	sim = Sim.new(cfg)

	_test_attack_anywhere()
	_test_crystal_no_block()
	_test_roll_distance()
	_test_roll_cooldown()
	_test_roll_iframe()
	_test_no_fire_while_rolling()
	_test_build_clamp()
	_test_scout_enemy_count()
	_test_wave_opening_burst()
	_test_shot_into_empty()

	print("CHECKS %d, FAILURES %d" % [checks, failures])
	print("FEATURES_SMOKE %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 2)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _to_build() -> void:
	sim.new_run(2026)
	sim.request("start_run")
	sim.request("return_city")


## 1) 建设期（城内）也能开火并命中
func _test_attack_anywhere() -> void:
	_to_build()
	sim.state.enemies.clear()
	var p: Vector2 = sim.state.player.pos
	var e := EnemyFactory.spawn(sim.state, cfg, "walker", p + Vector2(0, -8), 1.0, 1.0)
	e.hp = 9999.0
	var before := int(sim.state.stats["shots"])
	for i in range(14):
		sim.step(DT, {"fire": true, "aim": e.pos, "move": Vector2.ZERO})
	var fired := int(sim.state.stats["shots"]) - before
	_ok(sim.state.phase == GameState.Phase.BUILD, "处于建设期", str(sim.state.phase))
	_ok(fired > 0, "建设期可以开火", "shots+%d" % fired)
	_ok(e.hp < 9999.0, "建设期子弹能命中敌人", "hp=%.1f" % e.hp)


## 2) 水晶不再挡玩家子弹（城内朝任意方向都能打）
func _test_crystal_no_block() -> void:
	sim.new_run(2026)
	sim.request("start_run")
	sim.state.enemies.clear()
	var origin := Vector2(2.0, -5.5)      # 城内出生点，水晶在原点
	sim.state.player.pos = origin
	var hits := 0
	for target in [Vector2(2, 26), Vector2(-24, 0), Vector2(0, 30)]:
		var dir: Vector2 = (target - origin).normalized()
		var hit := Combat.resolve_shot(sim.state, origin, dir, 40.0)
		if String(hit["kind"]) == "enemy" or String(hit["kind"]) == "none":
			hits += 1
	_ok(hits == 3, "穿过水晶方向的射线不再被判成 crystal", "ok=%d/3" % hits)


## 3) 翻滚位移与自动结束
func _test_roll_distance() -> void:
	sim.new_run(2026)
	sim.request("start_run")
	sim.state.enemies.clear()
	var p0: Vector2 = sim.state.player.pos
	sim.step(DT, {"move": Vector2(1, 0), "aim": p0 + Vector2(0, -5), "roll": true})
	_ok(sim.state.player.rolling, "按右键当帧进入翻滚")
	_ok(sim.state.player.pos.distance_to(p0) > 0.05, "翻滚当帧就有位移")
	for i in range(30):
		sim.step(DT, {"move": Vector2.ZERO, "aim": p0 + Vector2(0, -5)})
	var moved: float = sim.state.player.pos.distance_to(p0)
	var want := float(cfg.num("roll", "distance", 4.2))
	_ok(absf(moved - want) < 0.8, "翻滚位移 ≈ %.1fm" % want, "实测 %.2f" % moved)
	_ok(not sim.state.player.rolling, "0.28s 后自动结束")


## 4) 冷却期间不能再翻滚
func _test_roll_cooldown() -> void:
	var before: Vector2 = sim.state.player.pos
	sim.step(DT, {"move": Vector2(1, 0), "roll": true})
	var again := sim.state.player.rolling
	_ok(not again, "冷却中按右键不会再次翻滚", "roll_cd=%.2f" % sim.state.player.roll_cd)
	_ok(sim.state.player.pos.distance_to(before) < 0.3, "冷却中也没有偷偷位移")


## 5) 无敌帧：帧内不掉血，帧外照常掉
func _test_roll_iframe() -> void:
	sim.new_run(2026)
	sim.request("start_run")
	sim.state.enemies.clear()
	var p: Vector2 = sim.state.player.pos
	var e := EnemyFactory.spawn(sim.state, cfg, "walker", p + Vector2(0.6, 0), 1.0, 1.0)
	e.dmg = 40.0
	e.interval = 0.2
	sim.state.player.roll_iframe = 0.25
	var hp0: float = sim.state.player.hp
	sim.step(DT, {"move": Vector2.ZERO})
	_ok(is_equal_approx(sim.state.player.hp, hp0), "无敌帧内贴身不掉血", "hp=%.3f" % sim.state.player.hp)
	sim.state.player.roll_iframe = 0.0
	for i in range(6):
		sim.step(DT, {"move": Vector2.ZERO})
	_ok(sim.state.player.hp < hp0, "无敌帧结束后照常承伤", "hp=%.2f" % sim.state.player.hp)


## 6) 翻滚期间不开火
func _test_no_fire_while_rolling() -> void:
	sim.new_run(2026)
	sim.request("start_run")
	sim.state.enemies.clear()
	var p: Vector2 = sim.state.player.pos
	var e := EnemyFactory.spawn(sim.state, cfg, "walker", p + Vector2(0, -9), 1.0, 1.0)
	e.hp = 9999.0
	var before := int(sim.state.stats["shots"])
	sim.step(DT, {"fire": true, "roll": true, "move": Vector2(1, 0), "aim": e.pos})
	for i in range(8):
		sim.step(DT, {"fire": true, "move": Vector2.ZERO, "aim": e.pos})
	_ok(int(sim.state.stats["shots"]) == before, "翻滚期间不消耗弹药",
		"shots %d -> %d" % [before, int(sim.state.stats["shots"])])


## 7) 建设期活动范围被限制在城墙圈内
func _test_build_clamp() -> void:
	_to_build()
	var wall_r := float(cfg.num("world", "wall_radius", 18.0))
	var limit := wall_r - 1.5
	for i in range(240):
		sim.step(DT, {"move": Vector2(1, 0)})
	var r: float = sim.state.player.pos.length()
	_ok(r <= limit + 0.01, "建设期被限制在城内", "r=%.2f limit=%.2f" % [r, limit])


## 8) 搜集期敌人数量收敛
func _test_scout_enemy_count() -> void:
	sim.new_run(2026)
	sim.request("start_run")
	var total := sim.state.enemies.size()
	var chasers := 0
	for e in sim.state.enemies:
		if not e.has_leash:
			chasers += 1
	_ok(total <= 5, "搜集期敌人 ≤ 5", "实测 %d" % total)
	_ok(chasers == 1, "游荡追兵 = 1", "实测 %d" % chasers)


## 9) 开波 2.5s 内先落 40% 敌潮
func _test_wave_opening_burst() -> void:
	_to_build()
	sim.request("start_wave")
	var n := sim.state.spawn_queue.size()
	var want := int(ceil(float(n) * 0.4))
	for i in range(150):        # 2.5s
		sim.step(DT, {"move": Vector2.ZERO, "aim": sim.state.player.pos + Vector2(0, -5)})
	_ok(sim.state.wave_spawned >= want, "开波 2.5s 内落场 ≥ 40%%",
		"spawned=%d want=%d total=%d" % [sim.state.wave_spawned, want, n])


## 10) 空地开枪也有可见弹道（原先弹道长度为 0，看起来像打不出枪）
func _test_shot_into_empty() -> void:
	sim.new_run(2026)
	sim.request("start_run")
	sim.state.enemies.clear()
	var p: Vector2 = sim.state.player.pos
	sim.state.player.fire_cd = 0.0
	sim.bus.clear()
	var ammo0 := sim.state.ammo
	sim.step(DT, {"fire": true, "aim": p + Vector2(0, -30), "move": Vector2.ZERO})
	var tracer := 0.0
	var got := false
	for ev in sim.drain_events():
		if String(ev["type"]) == EventBus.SHOT_FIRED:
			var d: Dictionary = ev["data"]
			tracer = (d["from"] as Vector2).distance_to(d["to"])
			got = true
	_ok(got, "空地开枪也发出 SHOT_FIRED 事件")
	_ok(tracer > 20.0, "空地弹道长度 ≈ 射程（不是 0）", "len=%.1f" % tracer)
	_ok(sim.state.ammo == ammo0 - 1, "空地开枪正常消耗 1 发弹药")