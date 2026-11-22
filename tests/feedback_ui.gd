extends SceneTree
## 界面反馈（2026-11-09 试玩反馈第二轮）：购买有回执、按钮写清价格与置灰、点击有涟漪。


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var probe := Node.new()
	probe.set_script(load("res://tests/feedback_ui_node.gd"))
	root.add_child(probe)