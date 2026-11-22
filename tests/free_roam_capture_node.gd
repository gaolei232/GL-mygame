extends Node
## 自由活动验收：把玩家瞬移到山上与地图边缘，验证
## 1) 不再有圆形空气墙（能到 ±153m）
## 2) 角色/相机跟随地形高度（不是浮在 y=0 平面）

var app: Node
var frames := 0


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)


func _process(_dt: float) -> void:
	frames += 1
	if frames == 2:
		app.sim.request("start_run")
	elif frames == 6:
		for e in app.sim.state.enemies:
			e.alive = false
		# 站到西南山脊上（原来是山，现在是可行走地形）
		_move_to(Vector2(-104.0, 72.0))
	elif frames == 90:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://shots/_shot_free_roam_hill.png")
		_report("hill", Vector2(-104.0, 72.0))
		# 再瞬移到地图边缘（离中心 213m，远超旧的 50m 限制）
		_move_to(Vector2(150.0, -150.0))
	elif frames == 170:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://shots/_shot_free_roam_edge.png")
		_report("edge", Vector2(150.0, -150.0))
		get_tree().quit(0)


func _move_to(p: Vector2) -> void:
	var s: GameState = app.sim.state
	s.player.pos = p
	app.sim.step(0.02, {"move": Vector2.ZERO})


func _report(tag: String, wanted: Vector2) -> void:
	var s: GameState = app.sim.state
	print("%s wanted=(%.0f,%.0f) actual=(%.1f,%.1f) dist=%.0f terrain_y=%.2f" % [
		tag, wanted.x, wanted.y, s.player.pos.x, s.player.pos.y,
		s.player.pos.length(), TerrainHeight.at(s.player.pos.x, s.player.pos.y)])