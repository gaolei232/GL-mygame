extends Node
## 敌人行走/攻击动画实机验收截图（全景）：开局→建设期→开波，把 4 种敌人排到同一段
## 城墙内侧，让逻辑驱动它们走到 1.6m 攻击距离；用游戏相机拍「集体砸墙」。
## 伤害置 0：只触发动作，不真的拆墙。
## 用法：godot --path . --script res://tests/enemy_attack_capture.gd

const KINDS := ["walker", "runner", "bomber", "brute"]

var app: Node
var units_layer: Node


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)
	units_layer = app.units
	_run()


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://shots/_enemy_anim_%s.png" % name)
	print("shot _enemy_anim_%s.png %s" % [name, str(img.get_size())])


func _spawn_lineup() -> void:
	var st = app.sim.state
	st.enemies.clear()
	st.spawn_queue.clear()
	st.summon_pending.clear()
	var seg = st.wall[0]
	var inward: Vector2 = -seg.center.normalized()
	var tangent: Vector2 = seg.tangent
	# 同一段城墙内侧排开：让它们自己走到 1.6m 攻击距离，朝向/攻击都由逻辑驱动
	for i in KINDS.size():
		var off := (float(i) - 1.5) * 2.2
		var pos: Vector2 = seg.center + inward * 2.8 + tangent * off
		var e := EnemyFactory.spawn(st, app.sim.cfg, KINDS[i], pos)
		e.dmg = 0.0
		print("SPAWNED %s id=%d pos=%s" % [KINDS[i], e.id, str(pos)])


func _run() -> void:
	await _wait(0.6)
	app.sim.request("start_run")
	await _wait(0.5)
	app.sim.request("return_city")
	await _wait(0.5)
	app.sim.request("start_wave")
	await _wait(0.5)
	# HUD 每帧被 app 重置 visible，这里用 alpha=0 藏掉；玩家模型也藏掉
	if app.hud != null:
		app.hud.modulate.a = 0.0
	if units_layer.player_model != null:
		units_layer.player_model.visible = false
	_spawn_lineup()
	await _wait(1.6)

	var seg0 = app.sim.state.wall[0]
	var inward0: Vector2 = -seg0.center.normalized()
	app.cam.camera.current = true
	app.cam.ortho_size = 9.0
	app.cam.camera.size = 9.0
	app.cam.follow(seg0.center + inward0 * 2.2, 1.0, true)
	await _wait(0.35)
	await _shot("attack_line")
	await _wait(0.45)
	await _shot("attack_line2")

	print("ANIM_CAPTURE kinds=%d" % KINDS.size())
	get_tree().quit(0)