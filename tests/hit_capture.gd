extends SceneTree
## 打击反馈截图：起波 → 在玩家面前放三只 → 手动发命中/击杀/受击事件 → 抓一帧。
## 只在窗口渲染下有效（--headless 没有 framebuffer，存图会是黑的）。


func _initialize() -> void:
	var scene: Node = load("res://main.tscn").instantiate()
	root.add_child(scene)
	var cap := Node.new()
	cap.set_script(load("res://tests/hit_capture_node.gd"))
	root.add_child(cap)