extends SceneTree
## P0-8 音频：素材加载、冷却、事件接线、残血心跳、音量联动。


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var probe := Node.new()
	probe.set_script(load("res://tests/audio_probe_node.gd"))
	root.add_child(probe)