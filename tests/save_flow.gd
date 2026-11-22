extends SceneTree
## app 层存档流程：进建设期自动落盘 → 主菜单「继续」→ 读回同一状态。
## 不渲染，--headless 可跑。


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var probe := Node.new()
	probe.set_script(load("res://tests/save_flow_node.gd"))
	root.add_child(probe)