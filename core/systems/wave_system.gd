class_name WaveSystem
extends RefCounted
## 波次导演：按 waves.tsv 生成敌人、驱动攻城、判定清场。
## 保留的核心玩法：5 波、每波一个新机制（runner / bomber / 双翼 / brute 召唤）、攻墙→破口→攻水晶。

const ATTACK_RANGE := 1.6
const CRYSTAL_RANGE := 3.6
const SUMMON_THRESHOLDS := [0.75, 0.5, 0.25]
const SUMMON_PER_THRESHOLD := 2


static func start(state: GameState, cfg: ConfigDB, bus: EventBus) -> void:
	var row := cfg.wave_row(state.wave_index)
	state.wave_elapsed = 0.0
	state.wave_killed = 0
	state.wave_spawned = 0
	state.spawn_queue.clear()
	state.summon_pending.clear()
	state.enemies.clear()

	var k_hp := float(row.get("k_hp", 1.0))
	var k_dmg := float(row.get("k_dmg", 1.0))
	state.rng.seed = state.seed_value + state.wave_index * 7919

	var kinds := ["walker", "runner", "bomber", "brute"]
	var total := 0
	for kind in kinds:
		var count := int(row.get(kind, 0))
		if count <= 0:
			continue
		total += count
		var gap := float(row.get("%s_gap" % kind, 1.5))
		var delay := float(row.get("%s_delay" % kind, 1.0))
		for i in range(count):
			var at := delay + gap * float(i)
			var wing := 0
			if state.wave_index == 4 and kind == "walker":
				wing = -1 if i % 2 == 0 else 1
				if wing > 0:
					at += 8.0    # 第 4 波双翼：右翼晚 8s
			state.spawn_queue.append({"kind": kind, "at": at, "wing": wing,
				"k_hp": k_hp, "k_dmg": k_dmg})
	state.spawn_queue.sort_custom(func(a, b): return float(a["at"]) < float(b["at"]))
	_apply_opening_burst(state, cfg)
	state.wave_total = total + int(row.get("summon_walker", 0))
	bus.emit(EventBus.WAVE_STARTED, {"wave": state.wave_index, "label": str(row.get("label", ""))})


static func step(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus) -> void:
	state.wave_elapsed += dt
	_spawn_due(state, cfg, bus)
	_tick_summons(state, dt, cfg)
	_update_enemies(state, dt, cfg, bus)

	if state.spawn_queue.is_empty() and state.summon_pending.is_empty() and state.alive_enemies().is_empty():
		bus.emit(EventBus.WAVE_CLEARED, {"wave": state.wave_index, "killed": state.wave_killed})
		if state.wave_index >= 5:
			PhaseMachine.enter(state, GameState.Phase.VICTORY, cfg, bus)
		else:
			PhaseMachine.enter(state, GameState.Phase.REWARD, cfg, bus)


## 开局集中落场（2026-11-08）：把前 N% 的敌人压进 opening_window 秒内，
## 让敌潮在开波瞬间「成规模出现」，而不是挤在搜集期；其余仍按 waves.tsv 的 gap 节奏。
## 只提前、不推迟：at = min(原 at, 窗口内均分)，所以不会制造空档。
static func _apply_opening_burst(state: GameState, cfg: ConfigDB) -> void:
	var ratio := clampf(float(cfg.num("wave", "opening_burst", 0.4)), 0.0, 1.0)
	var window := float(cfg.num("wave", "opening_window", 2.5))
	var n := state.spawn_queue.size()
	if n == 0 or ratio <= 0.0 or window <= 0.0:
		return
	var burst := int(ceil(float(n) * ratio))
	for i in range(burst):
		var item: Dictionary = state.spawn_queue[i]
		item["at"] = minf(float(item["at"]), window * float(i) / float(maxi(1, burst)))
	state.spawn_queue.sort_custom(func(a, b): return float(a["at"]) < float(b["at"]))


static func _spawn_due(state: GameState, cfg: ConfigDB, bus: EventBus) -> void:
	while not state.spawn_queue.is_empty():
		var item: Dictionary = state.spawn_queue[0]
		if float(item["at"]) > state.wave_elapsed:
			break
		state.spawn_queue.pop_front()
		var pos := EnemyFactory.perimeter_point(state, cfg, state.wave_spawned, max(1, state.wave_total), int(item["wing"]))
		EnemyFactory.spawn(state, cfg, str(item["kind"]), pos, float(item["k_hp"]), float(item["k_dmg"]))
		state.wave_spawned += 1


static func _tick_summons(state: GameState, dt: float, cfg: ConfigDB) -> void:
	for item in state.summon_pending.duplicate():
		item["delay"] = float(item["delay"]) - dt
		if float(item["delay"]) <= 0.0:
			state.summon_pending.erase(item)
			EnemyFactory.spawn(state, cfg, str(item["kind"]), item["pos"],
				float(item["k_hp"]), float(item["k_dmg"]))


static func _update_enemies(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus) -> void:
	for e in state.enemies:
		if not e.alive:
			continue
		e.atk_cd -= dt
		if e.kind == "brute":
			_check_summon(state, e, cfg)
		if e.phase == "fuse":
			e.fuse -= dt
			if e.fuse <= 0.0:
				_explode(state, e, cfg, bus)
			continue
		# 破口后的敌人才会追城内建造物；没掷中的按原逻辑拆墙
		var building := BuildSystem.enemy_building_target(state, cfg, e)
		if building != null:
			BuildSystem.advance_enemy_to_building(state, cfg, bus, e, building, dt)
			continue
		var seg := _target_segment(state, e)
		if seg == null:
			_advance_to_crystal(state, e, dt, bus)
		else:
			_advance_to_wall(state, e, seg, dt, bus)


static func _target_segment(state: GameState, e: GameState.EnemyState) -> GameState.WallSegment:
	if e.target_wall >= 0 and e.target_wall < state.wall.size():
		var cur: GameState.WallSegment = state.wall[e.target_wall]
		if not cur.breached:
			return cur
	var best := state.nearest_intact_wall(e.pos)
	if best != null:
		e.target_wall = best.index
	return best


static func _advance_to_wall(state: GameState, e: GameState.EnemyState, seg: GameState.WallSegment,
		dt: float, bus: EventBus) -> void:
	var dist := state.dist_to_wall(e.pos, seg)
	if dist <= ATTACK_RANGE:
		if e.kind == "bomber":
			e.phase = "fuse"
			e.fuse = 2.0
			return
		if e.atk_cd <= 0.0:
			e.atk_cd = e.interval
			seg.hp -= e.dmg
			seg.hit_flash = 0.18
			bus.emit(EventBus.ENEMY_ATTACK, {"id": e.id, "kind": e.kind})
			bus.emit(EventBus.WALL_HIT, {"index": seg.index, "dmg": e.dmg,
				"pos": seg.center, "by": e.kind})
			if seg.hp <= 0.0:
				seg.hp = 0.0
				seg.breached = true
				bus.emit(EventBus.WALL_BREACHED, {"index": seg.index, "pos": seg.center,
					"all_down": state.all_walls_down()})
		return
	var closest: Vector2 = seg.center + seg.tangent * clampf((e.pos - seg.center).dot(seg.tangent),
		-seg.half_len, seg.half_len)
	var dir := (closest - e.pos)
	if dir.length() > 0.05:
		e.pos += dir.normalized() * e.speed * dt


static func _advance_to_crystal(state: GameState, e: GameState.EnemyState, dt: float, bus: EventBus) -> void:
	var dist := e.pos.length()
	if dist <= CRYSTAL_RANGE:
		if e.atk_cd <= 0.0:
			e.atk_cd = e.interval
			state.crystal_hp -= e.dmg
			state.crystal_hit_flash = 0.25
			bus.emit(EventBus.ENEMY_ATTACK, {"id": e.id, "kind": e.kind})
			bus.emit(EventBus.CRYSTAL_HIT, {"dmg": e.dmg, "hp": state.crystal_hp})
		return
	e.pos += (-e.pos).normalized() * e.speed * dt


static func _explode(state: GameState, e: GameState.EnemyState, cfg: ConfigDB, bus: EventBus) -> void:
	# 自爆波及：先对 3m 内的建造物做 AOE（木箱/炮台），再按距离决定是否伤墙
	BuildSystem.damage_in_radius(state, cfg, bus, e.pos, 3.0, e.dmg, "bomber")
	var seg := _target_segment(state, e)
	if seg != null and state.dist_to_wall(e.pos, seg) <= 3.2:
		seg.hp -= e.dmg
		seg.hit_flash = 0.3
		bus.emit(EventBus.WALL_HIT, {"index": seg.index, "dmg": e.dmg, "pos": seg.center, "by": "bomber"})
		if seg.hp <= 0.0:
			seg.hp = 0.0
			seg.breached = true
			bus.emit(EventBus.WALL_BREACHED, {"index": seg.index, "pos": seg.center,
				"all_down": state.all_walls_down()})
	e.alive = false
	state.wave_killed += 1
	bus.emit(EventBus.ENEMY_DIED, {"id": e.id, "pos": e.pos, "kind": "bomber"})


static func _check_summon(state: GameState, e: GameState.EnemyState, cfg: ConfigDB) -> void:
	var ratio := e.hp / maxf(1.0, e.max_hp)
	for threshold in SUMMON_THRESHOLDS:
		if ratio <= threshold and not e.summon_done.has(threshold):
			e.summon_done.append(threshold)
			for i in range(SUMMON_PER_THRESHOLD):
				state.summon_pending.append({
					"kind": "walker", "delay": 0.5 + 0.3 * float(i),
					"pos": e.pos + Vector2(1.5, 0).rotated(float(i) * 1.6),
					"k_hp": float(cfg.wave_row(state.wave_index).get("k_hp", 1.0)),
					"k_dmg": float(cfg.wave_row(state.wave_index).get("k_dmg", 1.0)),
				})
