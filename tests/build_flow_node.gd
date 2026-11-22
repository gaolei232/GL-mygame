extends Node
## 悬停墙段时的提示文案（P0-7 升级 / 破口重建）。

var app: Node
var frames := 0
var checks := 0
var failures := 0


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _process(_dt: float) -> void:
	frames += 1
	match frames:
		2:
			app.sim.request("start_run")
		4:
			app.sim.request("return_city")        # BUILD
		6:
			var seg: GameState.WallSegment = app.sim.state.wall[0]
			seg.breached = true
			seg.hp = 0.0
			app._hover_wall = 0
			var hint: String = app._wall_hint()
			_ok(hint.find("重建") >= 0, "破口提示可按 E 重建", hint)
			_ok(hint.find("30 砖") >= 0 and hint.find("150 金") >= 0, "提示里写明重建成本", hint)

			PhaseMachine.enter(app.sim.state, GameState.Phase.WAVE, app.sim.cfg, app.sim.bus)
			_ok(app._wall_hint().find("重建") >= 0, "战斗期破口同样可重建")

			var seg0: GameState.WallSegment = app.sim.state.wall[0]
			seg0.breached = false
			seg0.hp = seg0.max_hp * 0.5
			var wave_hint: String = app._wall_hint()
			_ok(wave_hint.find("血量 50%") >= 0 and wave_hint.find("不能升级") >= 0,
				"战斗中完好段提示不能升级", wave_hint)

			PhaseMachine.enter(app.sim.state, GameState.Phase.BUILD, app.sim.cfg, app.sim.bus)
			var build_hint: String = app._wall_hint()
			_ok(build_hint.find("升级") >= 0 and build_hint.find("砖") >= 0,
				"建设期提示升级与价格", build_hint)

			app._hover_wall = -1
			app._aim = Vector2(0, -14)
			var build_hint2: String = app._wall_hint()
			_ok(build_hint2.find("建造城墙段") >= 0 and build_hint2.find("[E]") >= 0,
				"建设期指空地提示新建城墙段", build_hint2)
			_ok(build_hint2.find("%d 金" % app.sim.cfg.wall_build_coin_cost()) >= 0,
				"提示里带实时造价", build_hint2)
			app._aim = Vector2(0, 0)
			_ok(app._wall_hint().find("离水晶太近") >= 0, "压水晶上提示不能建",
				app._wall_hint())
			PhaseMachine.enter(app.sim.state, GameState.Phase.WAVE, app.sim.cfg, app.sim.bus)
			app._aim = Vector2(0, -14)
			_ok(app._wall_hint() == "", "战斗期不出建造提示（只能重建破口）")
			PhaseMachine.enter(app.sim.state, GameState.Phase.BUILD, app.sim.cfg, app.sim.bus)
		7:
			var box: VBoxContainer = app.hud._panel_box
			var bottom: float = box.position.y + box.size.y
			_ok(bottom < 720.0 - 90.0, "建设期右侧面板不压到底栏",
				"panel bottom=%.0f (上限 630)" % bottom)
			var sig1: String = app.hud._panel_signature()
			app.sim.state.player.weapon_levels["hammer"] = 2
			app.hud.update_snapshot(app.sim.snapshot())     # 签名读的是快照，不是 state
			var sig2: String = app.hud._panel_signature()
			_ok(sig1 != sig2, "锤子等级变化会触发面板重建（按钮文案才会刷新）")
			app.sim.state.player.weapon_levels["hammer"] = 1
			print("CHECKS %d, FAILURES %d" % [checks, failures])
			print("BUILD_FLOW %s" % ("PASS" if failures == 0 else "FAIL"))
			get_tree().quit(0 if failures == 0 else 2)