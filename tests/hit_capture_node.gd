extends Node
## 驱动 main.tscn 拍一张「打中了」的图：闪白 + 火花 + 伤害飘字 + 受击红闪。

var app: Node
var frames := 0
var enemies: Array = []
var control := OS.get_environment("HIT_CAPTURE_CONTROL") == "1"


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)


func _process(_dt: float) -> void:
	frames += 1
	match frames:
		5:
			app.sim.request("start_run")
		14:
			PhaseMachine.enter(app.sim.state, GameState.Phase.BUILD, app.sim.cfg, app.sim.bus)
			PhaseMachine.enter(app.sim.state, GameState.Phase.WAVE, app.sim.cfg, app.sim.bus)
			app.sim.state.spawn_queue.clear()
			app.sim.state.enemies.clear()
			var p: Vector2 = app.sim.state.player.pos
			enemies.append(EnemyFactory.spawn(app.sim.state, app.sim.cfg, "walker", p + Vector2(0, -4.0)))
			enemies.append(EnemyFactory.spawn(app.sim.state, app.sim.cfg, "walker", p + Vector2(2.4, -5.0)))
			enemies.append(EnemyFactory.spawn(app.sim.state, app.sim.cfg, "runner", p + Vector2(-2.4, -5.0)))
			app.sim.state.player.aim = p + Vector2(1.0, -6.0)
		20:
			# 直接走事件总线：等价于玩家这一枪命中了
			if not control:
				app.sim.bus.emit(EventBus.ENEMY_HIT, {"id": enemies[1].id, "pos": enemies[1].pos, "dmg": 37})
				app.sim.bus.emit(EventBus.ENEMY_HIT, {"id": enemies[2].id, "pos": enemies[2].pos, "dmg": 22})
		23:
			if not control:
				app.sim.bus.emit(EventBus.PLAYER_HURT, {"hp": 78.0, "dmg": 22})
		26:
			# 击杀 + 补一发命中：截图要在闪白窗口内（0.09s ≈ 5 帧）
			if not control:
				app.sim.bus.emit(EventBus.ENEMY_DIED, {"id": enemies[0].id, "pos": enemies[0].pos, "kind": "walker"})
				app.sim.state.enemies.erase(enemies[0])
				app.sim.bus.emit(EventBus.ENEMY_HIT, {"id": enemies[1].id, "pos": enemies[1].pos, "dmg": 41})
		27:
			for e in enemies:
				var v = app.units.enemy_views.get(e.id)
				if v != null:
					print("enemy %d flash=%.3f view=%s" % [e.id,
						float(app.units.enemy_fx.get(e.id, {}).get("flash", -1.0)),
						v.name])
			print("sparks=%d floaters=%d hurt=%.2f" % [
				app.fx._sparks.size(), app.hud._floaters.size(), app.hud._hurt_flash])
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			img.save_png("res://shots/_shot_hit_control.png" if control else "res://shots/_shot_hit_feedback.png")
			print("shot hit feedback")
			get_tree().quit(0)