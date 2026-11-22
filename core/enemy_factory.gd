class_name EnemyFactory
extends RefCounted
## 敌人实例工厂：把 TSV 行 × 波次倍率变成一个可模拟的 EnemyState。
## 唯一的敌人生成入口，scout 期与 wave 期共用，避免两套数值口径。

static func spawn(state: GameState, cfg: ConfigDB, kind: String, pos: Vector2,
		k_hp: float = 1.0, k_dmg: float = 1.0) -> GameState.EnemyState:
	var row := cfg.enemy_row(kind)
	var e := GameState.EnemyState.new()
	e.id = state.rng.randi_range(1, 1 << 30)
	e.kind = kind
	e.max_hp = float(row.get("hp", 100)) * k_hp
	e.hp = e.max_hp
	e.speed = float(row.get("speed", 40)) * 0.10   # TSV 速度为抽象单位，0.10 换算后 walker≈4 m/s
	e.dmg = float(row.get("dmg", 10)) * k_dmg
	e.interval = float(row.get("interval", 1.0))
	e.pos = pos
	e.target_wall = -1
	state.enemies.append(e)
	return e


static func perimeter_point(state: GameState, cfg: ConfigDB, index: int, count: int, wing: int = 0) -> Vector2:
	var radius := cfg.num("world", "spawn_radius", 38.0)
	var span := deg_to_rad(180.0)
	var t := (float(index) + 0.5) / maxf(1.0, float(count)) - 0.5
	var angle := t * span
	if wing < 0:
		angle = -absf(angle) - 0.15
	elif wing > 0:
		angle = absf(angle) + 0.15
	return Vector2(sin(angle), -cos(angle)) * radius
