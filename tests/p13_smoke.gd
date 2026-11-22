extends SceneTree
## P1-3 无头断言：精确瞄准只改“手感与可视”，不改判定规则。
## 覆盖：移速倍率、散布倍率来源、遮挡几何判定（相机→玩家连线是否穿墙）。

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

	_test_focus_speed()
	_test_focus_params()
	_test_occlusion_geometry()

	print("CHECKS %d, FAILURES %d" % [checks, failures])
	print("P13_SMOKE %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 2)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _test_focus_speed() -> void:
	sim.new_run(4242)
	sim.request("start_run")
	sim.state.enemies.clear()
	sim.state.player.pos = Vector2(0, 0)
	var normal := _measure_run(false)
	sim.state.player.pos = Vector2(0, 0)
	var focused := _measure_run(true)
	var ratio := focused / maxf(0.001, normal)
	_ok(absf(ratio - 0.6) < 0.03, "精确瞄准移速 ×0.6", "ratio=%.3f" % ratio)
	_ok(normal > focused, "精确瞄准移速低于常规", "normal=%.2f focus=%.2f" % [normal, focused])


func _measure_run(focus: bool) -> float:
	var start: Vector2 = sim.state.player.pos
	for i in range(30):
		sim.step(DT, {"move": Vector2.UP, "aim": Vector2.UP, "focus_aim": focus, "switch_to": -1})
	var moved := start.distance_to(sim.state.player.pos)
	sim.state.player.pos = start
	return moved


func _test_focus_params() -> void:
	var speed_mult := sim.cfg.num("aim", "focus_speed_mult", 0.6)
	var spread_mult := sim.cfg.num("aim", "focus_spread_mult", 0.5)
	var focus_factor := sim.cfg.num("camera", "focus_factor", 0.85)
	_ok(is_equal_approx(spread_mult, 0.5), "散布收紧倍率 = 0.5", str(spread_mult))
	_ok(is_equal_approx(speed_mult, 0.6), "移速倍率 = 0.6", str(speed_mult))
	_ok(is_equal_approx(focus_factor, 0.85), "相机正交尺寸倍率 = 0.85", str(focus_factor))


## 遮挡判定复用 Combat.ray_vs_segment：相机在城外侧上方，玩家贴墙内侧时应命中墙段
func _test_occlusion_geometry() -> void:
	var seg: GameState.WallSegment = sim.state.wall[3]
	var a: Vector2 = seg.center - seg.tangent * seg.half_len
	var b: Vector2 = seg.center + seg.tangent * seg.half_len
	var camera_xz: Vector2 = seg.center + Vector2(0, 30)      # 相机在墙外侧（+z）
	var player: Vector2 = seg.center + Vector2(0, -3.0)       # 玩家在墙内侧（-z）
	var dir: Vector2 = (player - camera_xz).normalized()
	var t := Combat.ray_vs_segment(camera_xz, dir, a, b)
	var length: float = camera_xz.distance_to(player)
	_ok(t > 0.0 and t < length, "相机→玩家连线穿过该墙段（应淡出）", "t=%.2f len=%.2f" % [t, length])

	var far_player: Vector2 = seg.center + Vector2(0, -12.0)
	var dir2: Vector2 = (far_player - camera_xz).normalized()
	var t2 := Combat.ray_vs_segment(camera_xz, dir2, a, b)
	_ok(t2 > 0.0, "玩家远离墙体时连线仍穿过墙段（说明只按几何遮挡判定）", "t=%.2f" % t2)
