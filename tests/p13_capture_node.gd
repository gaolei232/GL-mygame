extends Node

var app: Node
var frames := 0

func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)

func _process(_dt: float) -> void:
	frames += 1
	match frames:
		20:
			app.sim.request("start_run")
		40:
			app.sim.request("return_city")
		60:
			app.sim.request("start_wave")
		120:
			app.sim.state.player.pos = Vector2(6, -18)
			app.cam.follow(Vector2(6, -18), 0.0, true)
		199:
			var alphas: Array = []
			for seg_mats in app.world.wall_materials:
				for m in seg_mats:      # 每段一组材质（GLB 多 surface）
					alphas.append(snappedf(m.albedo_color.a, 0.01))
					break
			print("wall alphas=", alphas)
		200:
			_shot("_shot_occlusion.png")
		205:
			_press_right(true)
		260:
			_shot("_shot_focus_aim.png")
		265:
			_press_right(false)
		270:
			get_tree().quit(0)

func _press_right(pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = pressed
	ev.position = Vector2(640, 360)
	Input.parse_input_event(ev)

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://shots/" + name)
	print("shot ", name, " cam_size=", app.cam.camera.size)
