extends SceneTree
## 建造 UI 截图（窗口渲染专用）：建造面板 / 放置预览 / 木箱仓库。

func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var probe := Node.new()
	probe.set_script(load("res://tests/build_capture_node.gd"))
	root.add_child(probe)