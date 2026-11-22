extends Node
## 音频探针：真实 GameApp + AudioLayer。

var app: Node
var frames := 0
var checks := 0
var failures := 0


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _process(_dt: float) -> void:
	frames += 1
	match frames:
		2:
			app.sim.request("start_run")
		4:
			app.sim.request("return_city")
		6:
			var audio = app.audio
			_ok(audio.streams.size() == AudioLayer.SFX.size(), "全部音效加载（%d 个）" % AudioLayer.SFX.size(),
				"loaded=%d missing=%d" % [audio.streams.size(), audio.missing.size()])
			_ok(audio.missing.is_empty(), "没有缺失的素材文件", str(audio.missing.keys()))
			_ok(audio.play("hit"), "可以播放命中音")
			_ok(not audio.play("hit"), "冷却内的同一音效不重复播放")
		8:
			var audio = app.audio
			audio.reset_counts()
			app._apply_events([{"type": EventBus.ENEMY_HIT, "data": {"id": 1, "pos": Vector2.ZERO, "dmg": 10}}])
			_ok(audio.count("hit") == 1, "ENEMY_HIT → 命中音")
			app._apply_events([{"type": EventBus.ENEMY_DIED, "data": {"id": 1, "pos": Vector2.ZERO, "kind": "walker"}}])
			_ok(audio.count("kill") == 1, "ENEMY_DIED → 击杀音")
			app._apply_events([{"type": EventBus.SHOT_FIRED, "data": {"from": Vector2.ZERO, "to": Vector2.UP, "kind": "knife"}}])
			_ok(audio.count("knife") == 1, "SHOT_FIRED(knife) → 挥刀音")
			app._apply_events([{"type": EventBus.SHOT_FIRED, "data": {"from": Vector2.ZERO, "to": Vector2.UP, "kind": "crossbow"}}])
			_ok(audio.count("shot") == 1, "SHOT_FIRED(弩) → 射击音")
			app._apply_events([{"type": EventBus.PURCHASE, "data": {"key": "brick_pack", "name": "砖块包 ×20"}}])
			_ok(audio.count("buy") == 1, "购买 → 确认音")
			app._apply_events([{"type": EventBus.WALL_BREACHED, "data": {}}])
			_ok(audio.count("breach") == 1, "破口 → 破墙音")
			app._apply_events([{"type": EventBus.WALL_REPAIRED, "data": {"index": 0, "pos": Vector2.ZERO, "heal": 900.0}}])
			_ok(audio.count("repair") == 1, "修墙 → 锤击音")
			app._apply_events([{"type": EventBus.CRYSTAL_HIT, "data": {"dmg": 12}}])
			_ok(audio.count("crystal") == 1, "水晶受击 → 水晶音")
		10:
			var audio = app.audio
			audio.reset_counts()
			app.sim.state.player.hp = app.sim.state.player.max_hp * 0.2
			app._heartbeat_cd = 0.0
			app._process(0.016)
			_ok(audio.count("heartbeat") == 1, "残血（20%）触发心跳")
			audio.reset_counts()
			app.sim.state.player.hp = app.sim.state.player.max_hp
			app._heartbeat_cd = 0.0
			app._process(0.016)
			_ok(audio.count("heartbeat") == 0, "满血不播心跳")
		12:
			var audio = app.audio
			audio.reset_counts()
			app.sim.state.player.hp = app.sim.state.player.max_hp * 0.2
			app.set_paused(true)
			app._heartbeat_cd = 0.0
			app._process(0.016)
			_ok(audio.count("heartbeat") == 0, "暂停时不播心跳")
			app.set_paused(false)
		14:
			app._apply_settings({"volume": 0.1, "fullscreen": false, "quality": 1})
			var db := AudioServer.get_bus_volume_db(0)
			_ok(absf(db - linear_to_db(0.1)) < 0.5, "主音量设置作用于 Master 总线（音效同总线）",
				"db=%.2f 期望 %.2f" % [db, linear_to_db(0.1)])
			print("CHECKS %d, FAILURES %d" % [checks, failures])
			print("AUDIO_SMOKE %s" % ("PASS" if failures == 0 else "FAIL"))
			get_tree().quit(0 if failures == 0 else 2)