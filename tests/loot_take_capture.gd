extends SceneTree
## 拾取流程截图（窗口渲染专用）：扫完 -> 双击拾取 -> 已拾取划线。


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var probe := Node.new()
	probe.set_script(load("res://tests/loot_take_capture_node.gd"))
	root.add_child(probe)