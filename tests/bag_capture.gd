extends SceneTree

func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var cap := Node.new()
	cap.set_script(load("res://tests/bag_capture_node.gd"))
	root.add_child(cap)
