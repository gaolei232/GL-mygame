class_name GuardSystem
extends RefCounted
## 守卫系统（§5.3）：水晶守卫的补满、站位、目标选择与攻击。
## 规则边界：
##   1. 波内死亡不复活，`build` 阶段免费补满并复位（两条不可拆，见 §5.3 补充规则）。
##   2. 守卫是城内唯一防线，不做二道墙/陷阱。
##   3. 数值全部来自 `data/numeric/guards.tsv` 与 `balance.guard`。

const STATE_IDLE := "idle"
const STATE_INTERCEPT := "intercept"
const STATE_ATTACK := "attack"
const STATE_RETURN := "return"


## 进入 build 时调用：按水晶等级补齐、回满、复位站位。返回补充人数。
static func refresh(state: GameState, cfg: ConfigDB, bus: EventBus) -> int:
	var capacity := int(cfg.crystal_row(state.crystal_level).get("guard_count", 1))
	var alive_before := state.guards_alive().size()
	state.guard_capacity = capacity

	var rebuilt: Array = []
	for i in range(capacity):
		var guard: GameState.GuardState = null
		if i < state.guards.size():
			guard = state.guards[i]
		else:
			guard = _make_guard(state, cfg, i)
		guard.alive = true
		guard.hp = guard.max_hp
		guard.state = STATE_IDLE
		guard.target_id = -1
		guard.atk_cd = 0.0
		guard.station = station_of(cfg, i, capacity)
		guard.pos = guard.station
		rebuilt.append(guard)
	state.guards = rebuilt

	var refilled := maxi(0, capacity - alive_before)
	if refilled > 0 and state.phase != GameState.Phase.TITLE:
		bus.emit(EventBus.GUARD_REFILLED, {"count": capacity, "refilled": refilled})
	return refilled


static func station_of(cfg: ConfigDB, index: int, capacity: int) -> Vector2:
	var radius := cfg.num("guard", "station_radius", 5.5)
	var arc := deg_to_rad(cfg.num("guard", "station_arc_degrees", 150.0))
	var n := maxi(1, capacity)
	var t := (float(index) + 0.5) / float(n) - 0.5
	var angle := t * arc
	return Vector2(sin(angle), -cos(angle)) * radius


static func step(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus) -> void:
	if state.phase != GameState.Phase.WAVE:
		return
	var attack_range := cfg.num("guard", "attack_range", 1.6)
	var move_speed := cfg.num("guard", "move_speed", 3.5)
	var wall_radius := cfg.num("world", "wall_radius", 18.0)

	for guard in state.guards:
		if not guard.alive:
			continue
		guard.atk_cd = maxf(0.0, guard.atk_cd - dt)
		var target := _pick_target(state, cfg, guard)
		if target == null:
			_move_toward(guard, guard.station, move_speed, dt, wall_radius)
			guard.target_id = -1
			guard.state = STATE_IDLE if guard.pos.distance_to(guard.station) < 0.4 else STATE_RETURN
			continue
		guard.target_id = target.id
		var dist: float = guard.pos.distance_to(target.pos)
		if dist <= attack_range:
			guard.state = STATE_ATTACK
			if guard.atk_cd <= 0.0:
				guard.atk_cd = guard.interval
				Combat.damage_enemy(state, target, guard.dmg, bus)
		else:
			guard.state = STATE_INTERCEPT
			_move_toward(guard, target.pos, move_speed, dt, wall_radius)

	_apply_enemy_damage_to_guards(state, dt, bus)


## 目标优先级：①越破口且距水晶 ≤12m ②城内距水晶最近 ③无目标回站位
static func _pick_target(state: GameState, cfg: ConfigDB, guard: GameState.GuardState) -> GameState.EnemyState:
	var breach_near := cfg.num("guard", "breach_near_m", 12.0)
	var best: GameState.EnemyState = null
	var best_score := 1e9
	for e in state.enemies:
		if not e.alive or not _is_inside(state, e.pos):
			continue
		var crystal_dist: float = e.pos.length()
		var score := crystal_dist
		if crystal_dist > breach_near:
			score += 1000.0      # 第二优先级整体后置
		score += guard.pos.distance_to(e.pos) * 0.001
		if score < best_score:
			best_score = score
			best = e
	return best


static func _is_inside(state: GameState, pos: Vector2) -> bool:
	var radius := 12.0
	if not state.wall.is_empty():
		radius = (state.wall[0] as GameState.WallSegment).center.length()
	return pos.length() < radius


static func _move_toward(guard: GameState.GuardState, target: Vector2, speed: float,
		dt: float, wall_radius: float) -> void:
	var dir := target - guard.pos
	if dir.length() > 0.05:
		guard.pos += dir.normalized() * speed * dt
	if guard.pos.length() > wall_radius - 0.8:
		guard.pos = guard.pos.normalized() * (wall_radius - 0.8)


## 城内敌人优先打守卫：接触距离内的守卫按 `dmg - armor` 承伤
static func _apply_enemy_damage_to_guards(state: GameState, dt: float, bus: EventBus) -> void:
	for e in state.enemies:
		if not e.alive or not _is_inside(state, e.pos):
			continue
		var guard := state.nearest_guard(e.pos, 1.7)
		if guard == null:
			continue
		var raw := maxf(1.0, e.dmg - guard.armor)
		guard.hp -= raw * dt / maxf(0.2, e.interval)
		if guard.hp <= 0.0:
			guard.hp = 0.0
			guard.alive = false
			guard.state = STATE_IDLE
			bus.emit(EventBus.GUARD_DIED, {"id": guard.id, "pos": guard.pos})


static func _make_guard(state: GameState, cfg: ConfigDB, index: int) -> GameState.GuardState:
	var row := cfg.guard_row("default")
	var g := GameState.GuardState.new()
	g.id = 1000 + index
	g.max_hp = float(row.get("hp", 480))
	g.hp = g.max_hp
	g.armor = float(row.get("armor", 4))
	g.dmg = float(row.get("dmg", 16))
	g.interval = float(row.get("interval", 1.0))
	g.station = station_of(cfg, index, state.guard_capacity)
	g.pos = g.station
	return g
