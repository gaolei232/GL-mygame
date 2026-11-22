extends SceneTree
## 搜索式开箱界面截图（窗口渲染专用）。


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var probe := Node.new()
	probe.set_script(load("res://tests/search_capture_node.gd"))
	root.add_child(probe)