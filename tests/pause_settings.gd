extends SceneTree
## P1-1 暂停 / P1-2 设置：真实 main.tscn 驱动，--headless 可跑。


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var probe := Node.new()
	probe.set_script(load("res://tests/pause_settings_node.gd"))
	root.add_child(probe)