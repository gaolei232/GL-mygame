class_name Combat
extends RefCounted
## 命中解析：纯解析几何，不依赖物理引擎。
## 为什么不用 raycast：core 层必须是 headless 可测的纯逻辑，物理射线需要场景树。
## 口径：墙体不遮挡子弹（玩家越过墙顶射击），破口/遮挡只影响移动与视线可读性。

const HIT_RADIUS := 0.75


static func ray_vs_circle(origin: Vector2, dir: Vector2, center: Vector2, radius: float, max_dist: float) -> float:
	var to_c := center - origin
	var proj := to_c.dot(dir)
	if proj < -radius or proj > max_dist + radius:
		return -1.0
	var perp_sq := to_c.length_squared() - proj * proj
	if perp_sq > radius * radius:
		return -1.0
	var offset := sqrt(max(0.0, radius * radius - perp_sq))
	var t := proj - offset
	if t < 0.0:
		t = proj + offset
	if t < 0.0 or t > max_dist:
		return -1.0
	return t


static func ray_vs_segment(origin: Vector2, dir: Vector2, a: Vector2, b: Vector2) -> float:
	var seg := b - a
	var denom := dir.x * seg.y - dir.y * seg.x
	if absf(denom) < 1e-6:
		return -1.0
	var diff := a - origin
	var t := (diff.x * seg.y - diff.y * seg.x) / denom
	var u := (diff.x * dir.y - diff.y * dir.x) / denom
	if t >= 0.0 and u >= 0.0 and u <= 1.0:
		return t
	return -1.0


## 返回 {kind: enemy|wall|crystal|none, dist, enemy, wall_index, point}
static func resolve_shot(state: GameState, origin: Vector2, dir: Vector2, max_dist: float) -> Dictionary:
	# 默认「打空」：终点落在最大射程上，保证表现层永远有一条可见弹道。
	# 2026-11-08 修：原先终点取 origin，空射时弹道长度为 0、画不出线，
	# 玩家看到的就是「附近没敌人就开不了枪」。
	var best := {"kind": "none", "dist": max_dist, "enemy": null, "wall_index": -1,
		"point": origin + dir * max_dist}

	# 墙和水晶都不挡玩家子弹：墙只挡人（越过墙顶射击），水晶是友方建筑——
	# 让它挡弹会在城内造成「半个屏幕打不出去」的假故障（2026-11-08 修）。
	for e in state.enemies:
		if not e.alive:
			continue
		var t := ray_vs_circle(origin, dir, e.pos, HIT_RADIUS, best["dist"])
		if t >= 0.0 and t < best["dist"]:
			best = {"kind": "enemy", "dist": t, "enemy": e, "wall_index": -1,
				"point": origin + dir * t}
	return best


static func damage_enemy(state: GameState, enemy: GameState.EnemyState, dmg: float, bus: EventBus) -> void:
	if enemy == null or not enemy.alive:
		return
	enemy.hp -= dmg
	state.stats["hits"] = int(state.stats["hits"]) + 1
	bus.emit(EventBus.ENEMY_HIT, {"id": enemy.id, "pos": enemy.pos, "dmg": dmg})
	if enemy.hp <= 0.0:
		enemy.alive = false
		state.wave_killed += 1
		state.stats["kills"] = int(state.stats["kills"]) + 1
		bus.emit(EventBus.ENEMY_DIED, {"id": enemy.id, "pos": enemy.pos, "kind": enemy.kind})
