extends SceneTree
## P1-6 概率公示：数据来自 items.json、面板真的把数字画出来、Esc 能关。


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var probe := Node.new()
	probe.set_script(load("res://tests/odds_probe_node.gd"))
	root.add_child(probe)