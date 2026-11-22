extends Node

var frames := 0
var app: Node

func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)

func _process(_dt: float) -> void:
	frames += 1
	if frames == 20:
		for c in app.find_children("*", "Control", true, false):
			print("ctrl ", c.get_class(), " size=", c.size, " anchors R/B=", c.anchor_right, "/", c.anchor_bottom, " pos=", c.position)
	if frames == 30:
		_shot("_shot_title.png")
		app.sim.request("start_run")
	elif frames == 120:
		_shot("_shot_scout.png")
		app.sim.request("return_city")
	elif frames == 180:
		_shot("_shot_build.png")
		app.sim.request("start_wave")
	elif frames == 1800:
		_shot("_shot_wave.png")
		get_tree().quit(0)

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	# 统一写进 shots/（该目录带 .gdignore，不参与资源导入，也不会污染项目根）
	img.save_png("res://shots/" + name)
	print("shot ", name, " ", img.get_size())
