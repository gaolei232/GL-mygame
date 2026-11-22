extends Node
## 集成验收：近景拍主角（idle/fire/朝向）、水晶（满血/残血）与整局画面。
## 用法：godot --path . --script res://tests/integration_capture.gd

var frames := 0
var app: Node
var free_cam: Camera3D


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)
	free_cam = Camera3D.new()
	free_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	free_cam.fov = 45.0
	free_cam.near = 0.05
	free_cam.far = 100.0
	add_child(free_cam)


func _focus(pos: Vector2, size: float) -> void:
	app.cam.camera.current = true
	app.cam.ortho_size = size
	app.cam.camera.size = size
	app.cam.follow(pos, 1.0, true)


func _free_cam(loc: Vector3, target: Vector3) -> void:
	free_cam.global_position = loc
	free_cam.look_at(target, Vector3.UP)
	free_cam.current = true


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://shots/_integration_%s.png" % name)
	print("shot _integration_%s.png %s" % [name, str(img.get_size())])


func _player_pos() -> Vector3:
	return app.units.player_body.position


func _process(_dt: float) -> void:
	frames += 1
	match frames:
		30:
			app.sim.request("start_run")
		60:
			var p := _player_pos()
			_focus(Vector2(p.x, p.z), 5.0)
			print("hero_glb=", app.units.hero_uses_glb,
				" anim=", app.units.player_anim.current_animation if app.units.player_anim != null else "无",
				" meshes=", app.units.player_meshes.size(),
				" hand_bone=", app.units.player_hand_bone)
		68:
			_shot("player_idle")
		80:
			app.units.play_player_fire()
		100:
			_shot("player_fire")
		110:
			_focus(Vector2.ZERO, 5.5)
			print("crystal_effects=", app.world.crystal_effects.size(),
				" diamond=", app.world.crystal_diamond != null)
		118:
			_shot("crystal")
		126:
			app.sim.state.crystal_hp = app.sim.state.crystal_max_hp * 0.2
		140:
			_shot("crystal_hurt")
		152:
			# 从瞄准方向看玩家：应该看到兜帽里的暗腔（模型面向 -Z / 瞄准方向）
			var snap: Dictionary = app.sim.snapshot()
			var ppos: Vector2 = snap["player"]["pos"]
			var aim: Vector2 = snap["player"]["aim"]
			var dir := (aim - ppos)
			if dir.length() < 0.01:
				dir = Vector2(1, 0)
			dir = dir.normalized()
			var p3 := _player_pos()
			_free_cam(p3 + Vector3(dir.x, 0, dir.y) * 2.6 + Vector3(0, 1.6, 0),
				p3 + Vector3(0, 0.9, 0))
		160:
			_shot("player_front")
		168:
			var snap2: Dictionary = app.sim.snapshot()
			var ppos2: Vector2 = snap2["player"]["pos"]
			var aim2: Vector2 = snap2["player"]["aim"]
			var d2 := (aim2 - ppos2)
			if d2.length() < 0.01:
				d2 = Vector2(1, 0)
			d2 = d2.normalized()
			var p4 := _player_pos()
			_free_cam(p4 - Vector3(d2.x, 0, d2.y) * 2.6 + Vector3(0, 1.6, 0),
				p4 + Vector3(0, 0.9, 0))
		176:
			_shot("player_back")
		190:
			var p5 := _player_pos()
			_focus(Vector2(p5.x, p5.z), 22.0)
		220:
			app.sim.request("return_city")
		250:
			app.sim.request("start_wave")
		320:
			var snap3: Dictionary = app.sim.snapshot()
			var enemies: Array = snap3["enemies"]
			if enemies.size() > 0:
				var e: Dictionary = enemies[0]
				var ep: Vector2 = e["pos"]
				var wy: float = TerrainHeight.at(ep.x, ep.y)
				var eh: float = 3.2 if str(e["kind"]) == "brute" else 1.9
				_free_cam(Vector3(ep.x - eh * 1.5, wy + eh * 0.95, ep.y + eh * 1.7),
					Vector3(ep.x, wy + eh * 0.55, ep.y))
				print("enemy_closeup kind=", e["kind"], " count=", enemies.size())
		336:
			_shot("enemy_wave1")
		350:
			var p6 := _player_pos()
			_focus(Vector2(p6.x, p6.z), 22.0)
		470:
			_shot("wave")
		480:
			get_tree().quit(0)