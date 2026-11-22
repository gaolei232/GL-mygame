extends SceneTree
## 暂停 / 设置界面截图。只在窗口渲染下有效。


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var probe := Node.new()
	probe.set_script(load("res://tests/ui_pause_capture_node.gd"))
	root.add_child(probe)