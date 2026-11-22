extends SceneTree
## 数值验收：运动朝向（应朝移动方向、而非准星）+ 动画状态机选到 walk/run/roll。
## 用法：godot --headless --path . --script res://tests/hero_facing_probe.gd

var app: Node
var f := 0
var phase := "wait"
var fails := 0


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	app = root.find_child("GameApp", true, false)


func _ok(cond: bool, label: String, detail: String = "") -> void:
	if cond:
		print("PASS ", label, "  ", detail)
	else:
		fails += 1
		print("FAIL ", label, "  ", detail)


func _yaw() -> float:
	return app.units.player_yaw


func _anim() -> String:
	var ap: AnimationPlayer = app.units.player_anim
	return ap.current_animation if ap != null else "none"


func _process(dt: float) -> bool:
	if app == null:
		app = root.find_child("GameApp", true, false)
		if app == null:
			return false
	f += 1
	var p = app.sim.state.player
	match f:
		20:
			app.sim.request("start_run")
		40:
			phase = "walk"          # 朝 +X 移动 3 m/s，准星朝 -Y
		90:
			var exp_move := atan2(-1.0, 0.0)   # 面向 +X
			_ok(abs(_yaw() - exp_move) < 0.25, "移动时面向移动方向(+X)",
				"yaw=%.2f expected=%.2f" % [_yaw(), exp_move])
			_ok(_anim() == "walk", "3 m/s 播 walk", _anim())
			phase = "run"
		100:
			pass
		150:
			var exp_move2 := atan2(-1.0, 0.0)
			_ok(abs(_yaw() - exp_move2) < 0.2, "跑动时仍面向移动方向(+X)",
				"yaw=%.2f expected=%.2f" % [_yaw(), exp_move2])
			_ok(_anim() == "run", "12 m/s 播 run", _anim())
			phase = "roll"
			p.rolling = true
			p.roll_timer = 0.30
			p.roll_dir = Vector2(0, 1)     # 朝 +Y 滚（与移动 +X、准星 -Y 都不同）
		155:
			_ok(_anim() == "roll", "翻滚播 roll", _anim())
		160:
			pass
		170:
			var exp_roll := atan2(0.0, -1.0)   # 面向 +Y
			_ok(abs(angle_difference(_yaw(), exp_roll)) < 0.3, "翻滚时面向翻滚方向(+Y)",
				"yaw=%.2f expected=%.2f" % [_yaw(), exp_roll])
			phase = "stop"
			p.rolling = false
			p.roll_timer = 0.0
		_:
			# 站定后应转回准星（-Y → yaw 0）。headless 帧率极高，
			# 按帧数等会误判，这里轮询到收敛或超时。
			if phase == "stop":
				if abs(angle_difference(_yaw(), 0.0)) < 0.2:
					_ok(true, "站定后转向准星(-Y)", "yaw=%.2f" % _yaw())
					_ok(_anim() == "idle", "站定播 idle", _anim())
					print("CHECKS_FAILED ", fails)
					quit(1 if fails > 0 else 0)
				elif f > 20000:
					_ok(false, "站定后转向准星(-Y)",
						"yaw=%.2f 未收敛" % _yaw())
					print("CHECKS_FAILED ", fails)
					quit(1)

	# 制造速度：按相位推进位置（+X），准星恒在 -Y
	if phase == "walk":
		p.pos += Vector2(3.0, 0.0) * dt
	elif phase == "run":
		p.pos += Vector2(12.0, 0.0) * dt
	p.aim = p.pos + Vector2(0, -4.0)
	return false