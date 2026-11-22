extends SceneTree
## P0-3 打击反馈：中弹闪白状态机、死亡 0.3s 过渡、火花池回收。
## 只测表现层的状态与生命周期（不渲染），所以 --headless 可跑。

const DT := 1.0 / 60.0

var checks := 0
var failures := 0


func _initialize() -> void:
	var units := UnitLayer.new()
	root.add_child(units)
	units.setup()
	var fx := FxLayer.new()
	root.add_child(fx)
	fx.setup()

	var snap := {
		"player": {"pos": Vector2.ZERO, "aim": Vector2.UP, "alive": true,
			"hurt_flash": 0.0, "rolling": false, "active_slot": 0,
			"slots": ["crossbow", ""], "weapon_levels": {}},
		"enemies": [{"id": 7, "kind": "walker", "pos": Vector2(3, 0), "fuse": 0.0}],
		"guards": [],
		"loot": [],
	}
	units.sync(snap, DT)
	_ok(units.enemy_views.has(7), "敌人视图创建")

	units.flash_enemy(7)
	_ok(float(units.enemy_fx[7]["flash"]) > 0.0, "中弹进入闪白状态",
		"flash=%.3f" % float(units.enemy_fx[7]["flash"]))

	for i in range(int(0.12 / DT)):
		units.sync(snap, DT)
	_ok(float(units.enemy_fx[7]["flash"]) <= 0.0, "闪白在 0.09s 内衰减完",
		"flash=%.3f" % float(units.enemy_fx[7]["flash"]))

	# 敌人从快照消失 = 这一帧死了：视图必须留 0.3s，不能瞬间 queue_free
	var empty := snap.duplicate(true)
	empty["enemies"] = []
	units.sync(empty, DT)
	_ok(units.enemy_views.has(7) and float(units.enemy_fx[7]["dying"]) > 0.0,
		"死亡后视图保留（0.3s 过渡中）", "dying=%.3f" % float(units.enemy_fx.get(7, {}).get("dying", 0.0)))

	for i in range(int(0.4 / DT)):
		units.sync(empty, DT)
	_ok(not units.enemy_views.has(7) and not units.enemy_fx.has(7), "0.3s 后视图与状态一并移除")

	fx.burst(Vector2.ZERO)
	_ok(fx._sparks.size() == 1, "命中火花入池")
	fx.tick(0.3)
	_ok(fx._sparks.is_empty(), "火花 0.16s 后回收")
	_ok(fx._spark_free.size() == FxLayer.SPARK_POOL, "池全部归还",
		"free=%d" % fx._spark_free.size())

	print("CHECKS %d, FAILURES %d" % [checks, failures])
	print("FEEDBACK_SMOKE %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 2)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)