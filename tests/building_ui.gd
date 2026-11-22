extends SceneTree
## 建造 UI（2026-11-10）：真实 GameApp 里的面板列表、放置、拆除、木箱仓库。


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var probe := Node.new()
	probe.set_script(load("res://tests/building_ui_node.gd"))
	root.add_child(probe)