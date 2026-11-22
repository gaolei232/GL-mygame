extends Node
## 主角动画验收：走/跑/翻滚 + 「运动时面向移动方向」。
## 用法：godot --path . --script res://tests/hero_anim_capture.gd
## 做法：直接改玩家 pos 制造速度（view 按位置差算 speed 选 walk/run），
##       翻滚直接置 rolling/roll_dir（等价于右键触发后的状态）。

const CAM_CLOSE := 6.0
var frames := 0
var app: Node
var free_cam: Camera3D
var move_dir := Vector2(1, 0)
var move_speed := 0.0
var roll_left := 0.0


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)
	free_cam = Camera3D.new()
	free_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	free_cam.fov = 42.0
	free_cam.near = 0.05
	free_cam.far = 120.0
	add_child(free_cam)


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://shots/_anim_%s.png" % name)
	print("shot _anim_%s.png %s" % [name, str(img.get_size())])


func _focus(size: float) -> void:
	var p: Vector3 = app.units.player_body.position
	app.cam.camera.current = true
	app.cam.ortho_size = size
	app.cam.camera.size = size
	app.cam.follow(Vector2(p.x, p.z), 1.0, true)


## 侧后方自由相机：能看出身体朝哪边
func _side_cam() -> void:
	var p: Vector3 = app.units.player_body.position
	free_cam.global_position = p + Vector3(-2.4, 1.5, 2.4)
	free_cam.look_at(p + Vector3(0, 0.9, 0), Vector3.UP)
	free_cam.current = true


func _process(dt: float) -> void:
	frames += 1
	var p = app.sim.state.player
	match frames:
		25:
			app.sim.request("start_run")
		50:
			# 走：3 m/s，朝 +X 移动，准星故意朝 -Y（验证「面向移动方向」而不是准星）
			move_speed = 3.0
		70:
			_side_cam()
		74:
			await _shot("walk_side")
		76:
			_focus(CAM_CLOSE)
		80:
			await _shot("walk_top")
		85:
			# 跑：12 m/s（基础 7 / 冲刺 14 之间），仍朝 +X
			move_speed = 12.0
		105:
			_side_cam()
		109:
			await _shot("run_side")
		111:
			_focus(CAM_CLOSE)
		115:
			await _shot("run_top")
		120:
			# 翻滚：朝 +X 滚，每隔几帧抓一张
			move_speed = 8.0
			p.rolling = true
			p.roll_timer = 0.28
			p.roll_dir = move_dir
			roll_left = 0.28
		125:
			await _shot("roll_a")
		130:
			await _shot("roll_b")
		135:
			await _shot("roll_c")
		142:
			move_speed = 0.0
		150:
			get_tree().quit(0)

	# 造速度：按当前 move_speed 推进玩家位置（翻滚期间也用同一推进，模拟翻滚位移）
	if move_speed > 0.01 and p.alive:
		p.pos += move_dir * move_speed * dt
		p.aim = p.pos + Vector2(0, -4.0)      # 准星始终朝 -Y，与移动方向垂直