extends SceneTree
## P1-3 视觉验证：遮挡淡出 + 右键精确瞄准，各截一张。

func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var cap := Node.new()
	cap.set_script(load("res://tests/p13_capture_node.gd"))
	root.add_child(cap)
