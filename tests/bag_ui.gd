extends SceneTree
## 背包系统（2026-11-10）：B 键开关、冻结 sim、装备/卸下/卖出、容量与属性展示。


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var probe := Node.new()
	probe.set_script(load("res://tests/bag_probe_node.gd"))
	root.add_child(probe)