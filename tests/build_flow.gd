extends SceneTree
## 建造提示（破口重建 / 建设中升级）在真实 GameApp 里的文案与阶段判定。


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var probe := Node.new()
	probe.set_script(load("res://tests/build_flow_node.gd"))
	root.add_child(probe)