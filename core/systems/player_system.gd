class_name PlayerSystem
extends RefCounted
## 玩家系统：移动、瞄准、射击、近战、修墙、死亡与复活。
## 保留的核心玩法：两把枪槽共享公共弹药 + 锤/刀独立工具 + 死亡递增惩罚。
## 表现层只提供“意图”（move/aim/fire），不参与命中判定。

const SLOT_GUN_A := 0
const SLOT_GUN_B := 1
const SLOT_HAMMER := 2
const SLOT_KNIFE := 3


static func step(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus, cmd: Dictionary) -> void:
	var p := state.player
	if not p.alive:
		p.respawn_timer -= dt
		if p.respawn_timer <= 0.0:
			_respawn(state, cfg, bus)
		return

	var move: Vector2 = cmd.get("move", Vector2.ZERO)
	if move.length() > 1.0:
		move = move.normalized()
	p.moving = move

	# 计时器无条件推进：翻滚期间也得让冷却/受击闪烁继续走
	p.fire_cd = maxf(0.0, p.fire_cd - dt)
	p.melee_cd = maxf(0.0, p.melee_cd - dt)
	p.hurt_flash = maxf(0.0, p.hurt_flash - dt)
	p.roll_cd = maxf(0.0, p.roll_cd - dt)
	p.blink_cd = maxf(0.0, p.blink_cd - dt)
	p.roll_iframe = maxf(0.0, p.roll_iframe - dt)
	if p.rolling:
		p.roll_timer -= dt
		if p.roll_timer <= 0.0:
			p.rolling = false
			p.roll_timer = 0.0

	# 主动技能「瞬移」：向移动输入方向（没输入就朝准星）瞬移固定距离。
	# 冷却中给明确反馈，否则玩家会以为技能坏了。
	if bool(cmd.get("blink", false)):
		if p.blink_cd > 0.0:
			bus.emit(EventBus.NOTICE, {"text": "瞬移冷却中 · %.1fs" % p.blink_cd})
		else:
			var bdir := move
			if bdir.length() < 0.1:
				bdir = p.aim - p.pos
			if bdir.length() < 0.1:
				bdir = Vector2(0, -1)
			var from_pos := p.pos
			p.pos += bdir.normalized() * float(cfg.num("player", "blink_distance", 3.0))
			_clamp_pos(state, cfg)
			p.blink_cd = float(cfg.num("player", "blink_cd", 10.0))
			bus.emit(EventBus.PLAYER_BLINK, {"from": from_pos, "to": p.pos})
	if bool(cmd.get("roll", false)) and not p.rolling and p.roll_cd <= 0.0:
		_start_roll(state, cfg, bus, move)

	if p.rolling:
		# 翻滚期间：固定方向位移，不吃移动输入 / 冲刺 / 精确瞄准减速，也不开火
		var roll_dist := float(cfg.num("roll", "distance", 4.2))
		var roll_time := maxf(0.05, float(cfg.num("roll", "duration", 0.28)))
		p.pos += p.roll_dir * (roll_dist / roll_time) * dt
		_clamp_pos(state, cfg)
		p.aim = cmd.get("aim", p.aim + Vector2(0, -1))
		_apply_enemy_damage(state, dt, cfg, bus)
		return

	var focus_aim := bool(cmd.get("focus_aim", false))
	var speed := cfg.num("player", "speed", 7.0)
	if bool(cmd.get("sprint", false)) and not (focus_aim and bool(cfg.balance.get("player", {}).get("sprint_focus_block", true))):
		speed *= cfg.num("player", "sprint_mult", 1.35)
	if focus_aim:
		speed *= cfg.num("aim", "focus_speed_mult", 0.6)
	speed *= float(state.mods.get("speed", 1.0))
	p.pos += move * speed * dt
	_clamp_pos(state, cfg)
	p.aim = cmd.get("aim", p.aim + Vector2(0, -1))

	var switch_to := int(cmd.get("switch_to", -1))
	if switch_to >= 0 and switch_to <= 3 and switch_to != p.active_slot:
		# 空枪槽必须给提示：否则按 2 之后点击毫无反应，玩家会以为「弩没了」
		if switch_to <= SLOT_GUN_B and str(p.slots[switch_to]) == "":
			bus.emit(EventBus.NOTICE, {"text": "槽 %d 空置 · 按 1 切回，或去商店买「轻弩」" % (switch_to + 1)})
		p.active_slot = switch_to

	match p.active_slot:
		SLOT_GUN_A, SLOT_GUN_B:
			if bool(cmd.get("fire", false)):
				_try_shoot(state, cfg, bus, bool(cmd.get("focus_aim", false)))
		SLOT_HAMMER:
			if bool(cmd.get("fire", false)) or bool(cmd.get("action", false)):
				_try_repair(state, dt, cfg, bus)
		SLOT_KNIFE:
			if bool(cmd.get("fire", false)):
				_try_melee(state, cfg, bus)
		_:
			if p.active_slot <= SLOT_GUN_B and bool(cmd.get("fire", false)) \
					and str(p.slots[p.active_slot]) == "longsword":
				_try_weapon_melee(state, cfg, bus, "longsword")

	_apply_enemy_damage(state, dt, cfg, bus)


## 翻滚（2026-11-08）：方向优先取移动输入，没有输入就朝准星；无敌帧只挡接触伤害。
static func _start_roll(state: GameState, cfg: ConfigDB, bus: EventBus, move_dir: Vector2) -> void:
	var p := state.player
	var dir := move_dir
	if dir.length() < 0.1:
		dir = p.aim - p.pos
	if dir.length() < 0.1:
		dir = Vector2(0, -1)
	p.roll_dir = dir.normalized()
	p.rolling = true
	p.roll_timer = float(cfg.num("roll", "duration", 0.28))
	p.roll_cd = float(cfg.num("roll", "cooldown", 0.9))
	p.roll_iframe = float(cfg.num("roll", "iframe", 0.2))
	bus.emit(EventBus.PLAYER_ROLL, {"pos": p.pos, "dir": p.roll_dir})


## 活动范围（2026-11-15 二改）：**整张地图自由活动**，不再有圆形空气墙。
## - 建设期仍锁在城墙圈内（玩法要求，不是空气墙）
## - 其余阶段：限制在地图方形边界内；河道是唯一不可通行地形
## 视觉上"站多高"由 TerrainHeight 在表现层解决，core 保持纯 2D。
static func _clamp_pos(state: GameState, cfg: ConfigDB) -> void:
	var p := state.player
	if state.phase == GameState.Phase.BUILD:
		var limit := maxf(6.0, cfg.num("world", "wall_radius", 18.0) - 1.5)
		if p.pos.length() > limit:
			p.pos = p.pos.normalized() * limit
		return
	var half := cfg.num("world", "map_half", 160.0) - cfg.num("world", "map_margin", 7.0)
	p.pos.x = clampf(p.pos.x, -half, half)
	p.pos.y = clampf(p.pos.y, -half, half)
	_block_river(state, cfg)


## 河道不可通行：走到岸边就沿法线推回去（水与地图边界是仅有的两处限制）
static func _block_river(state: GameState, cfg: ConfigDB) -> void:
	var pts: Array = cfg.river_points
	if pts.size() < 2:
		return
	var p := state.player
	var block := cfg.river_half_width + cfg.num("world", "river_margin", 1.2)
	var best_d := 1e9
	var best_c := Vector2.ZERO
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var ab := b - a
		var t := clampf((p.pos - a).dot(ab) / maxf(0.0001, ab.length_squared()), 0.0, 1.0)
		var c := a + ab * t
		var d := p.pos.distance_to(c)
		if d < best_d:
			best_d = d
			best_c = c
	if best_d >= block:
		return
	var push := p.pos - best_c
	if push.length() < 0.01:
		push = Vector2(1, 0)
	p.pos = best_c + push.normalized() * block


static func _try_shoot(state: GameState, cfg: ConfigDB, bus: EventBus, focus_aim: bool = false) -> void:
	var p := state.player
	if p.fire_cd > 0.0:
		return
	var weapon_id := str(p.slots[p.active_slot]) if p.active_slot <= SLOT_GUN_B else ""
	if weapon_id == "longsword":
		if p.melee_cd <= 0.0:
			_try_weapon_melee(state, cfg, bus, weapon_id)
		return
	if weapon_id == "":
		bus.emit(EventBus.NOTICE, {"text": "槽位为空 · 按 1 切回弩"})
		p.fire_cd = 0.4
		return
	var row := cfg.weapon_level_row(weapon_id, int(p.weapon_levels.get(weapon_id, 1)))
	if row.is_empty():
		return
	var cost := int(cfg.balance.get("weapons", {}).get(weapon_id, {}).get("ammo_per_shot", 1))
	if cost > 0 and state.ammo < cost:
		bus.emit(EventBus.NOTICE, {"text": "弹药耗尽 · 切小刀（4）或回城购买"})
		p.fire_cd = 0.3
		return
	if cost > 0:
		InventorySystem.spend(state, "ammo", cost)

	var spread := float(cfg.balance.get("weapons", {}).get(weapon_id, {}).get("spread", 0.04))
	if focus_aim:
		spread *= cfg.num("aim", "focus_spread_mult", 0.5)
	spread *= float(state.mods.get("spread", 1.0))
	var dir: Vector2 = p.aim - p.pos
	if dir.length() < 0.1:
		dir = Vector2(0, -1)
	dir = dir.normalized().rotated(state.rng.randf_range(-spread, spread))
	var max_dist := float(cfg.balance.get("weapons", {}).get(weapon_id, {}).get("range", 26.0))

	p.fire_cd = float(row.get("interval", 0.42)) * float(state.mods.get("rate", 1.0))
	state.stats["shots"] = int(state.stats["shots"]) + 1

	var hit := Combat.resolve_shot(state, p.pos, dir, max_dist)
	bus.emit(EventBus.SHOT_FIRED, {"from": p.pos, "to": hit["point"], "kind": weapon_id})
	if hit["kind"] == "enemy":
		Combat.damage_enemy(state, hit["enemy"], float(row.get("atk", 34.0)) * float(state.mods.get("dmg", 1.0)), bus)


static func _try_melee(state: GameState, cfg: ConfigDB, bus: EventBus) -> void:
	_try_weapon_melee(state, cfg, bus, "knife")


static func _try_weapon_melee(state: GameState, cfg: ConfigDB, bus: EventBus, weapon_id: String) -> void:
	var p := state.player
	if p.melee_cd > 0.0:
		return
	var row := cfg.weapon_level_row(weapon_id, int(p.weapon_levels.get(weapon_id, 1)))
	var reach := float(cfg.balance.get("weapons", {}).get(weapon_id, {}).get("range", 2.6))
	var aim_dir: Vector2 = (p.aim - p.pos).normalized()
	if aim_dir.length() < 0.1:
		aim_dir = Vector2(0, -1)
	var target: GameState.EnemyState = null
	var best := reach
	for e in state.enemies:
		if not e.alive:
			continue
		var to_e: Vector2 = e.pos - p.pos
		if to_e.length() > best:
			continue
		if to_e.length() > 0.2 and aim_dir.dot(to_e.normalized()) < 0.2:
			continue
		best = to_e.length()
		target = e
	p.melee_cd = float(row.get("interval", 0.42)) * float(state.mods.get("rate", 1.0))
	bus.emit(EventBus.SHOT_FIRED, {"from": p.pos, "to": p.pos + aim_dir * reach, "kind": weapon_id})
	if target != null:
		Combat.damage_enemy(state, target, float(row.get("atk", 29.0)) * float(state.mods.get("dmg", 1.0)), bus)


static func _try_repair(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus) -> void:
	var p := state.player
	if p.melee_cd > 0.0:
		return
	var reach := float(cfg.balance.get("weapons", {}).get("hammer", {}).get("range", 3.2))
	var level := int(p.weapon_levels.get("hammer", 1))
	var row := cfg.weapon_level_row("hammer", level)
	var heal := float(row.get("atk", cfg.num("wall_rules", "repair_hp_per_brick", 120.0))) \
		* float(state.mods.get("repair", 1.0))
	# 木箱/炮台也能修：光标明确指着建造物时优先修它；否则墙体优先，
# 身边没有可修墙段时才退到最近的受伤建造物（避免「瞄墙却修了旁边的箱子」）。
	var aimed_building := BuildSystem.building_at_point(state, cfg, p.aim, 1.0)
	if aimed_building != null and aimed_building.hp < aimed_building.max_hp - 0.5 \
			and p.pos.distance_to(aimed_building.pos) <= reach:
		_repair_building_action(state, cfg, bus, p, aimed_building, heal, row)
		return
	# 优先修「光标指着的那一段」（选择位置的语义），够不着再退回身边最近的有损伤段
	var seg: GameState.WallSegment = null
	var aimed := state.wall_segment_at(p.aim, 1.8)
	if aimed >= 0:
		var candidate: GameState.WallSegment = state.wall[aimed]
		if candidate.hp < candidate.max_hp - 0.5 and state.dist_to_wall(p.pos, candidate) <= reach:
			seg = candidate
	if seg == null:
		seg = state.nearest_damaged_wall(p.pos, reach)
	if seg == null:
		var near_building := BuildSystem.repairable_at(state, cfg, p.pos, p.aim, reach)
		if near_building != null:
			_repair_building_action(state, cfg, bus, p, near_building, heal, row)
			return
		# 够不着 / 附近都满血：给一句明确的话，别让玩家以为「砖没用」
		if state.nearest_intact_wall(p.pos, reach) != null:
			bus.emit(EventBus.NOTICE, {"text": "附近城墙都是满血"})
		else:
			bus.emit(EventBus.NOTICE, {"text": "靠近城墙才能修"})
		p.melee_cd = 0.25
		return
	var cost := int(cfg.num("wall_rules", "repair_brick_cost", 1))
	if state.brick < cost:
		bus.emit(EventBus.NOTICE, {"text": "砖块不足 · 商店买砖块包"})
		p.melee_cd = 0.25
		return
	var before := seg.hp
	InventorySystem.spend(state, "brick", cost)
	seg.hp = minf(seg.max_hp, seg.hp + heal)
	var actual := seg.hp - before
	state.stats["repair_hp"] = float(state.stats["repair_hp"]) + actual
	p.melee_cd = float(row.get("interval", 0.35))
	bus.emit(EventBus.WALL_REPAIRED, {"index": seg.index, "hp": seg.hp, "pos": seg.center,
		"heal": actual, "level": level})


static func _repair_building_action(state: GameState, cfg: ConfigDB, bus: EventBus,
		p: GameState.PlayerState, b: GameState.BuildingState, heal: float, row: Dictionary) -> void:
	var cost := int(cfg.build_rule("repair_brick_cost", 1))
	if state.brick < cost:
		bus.emit(EventBus.NOTICE, {"text": "砖块不足 · 商店买砖块包"})
		p.melee_cd = 0.25
		return
	InventorySystem.spend(state, "brick", cost)
	BuildSystem.repair_building(state, bus, b, heal)
	p.melee_cd = float(row.get("interval", 0.35))


## 承伤口径：搜集期敌人锁定玩家；战斗期只有「已越过城墙」的敌人才会伤到玩家，
## 墙外的敌人只拆墙——否则站在墙后就会把整波火力吸引到自己身上（问题 #3）。
static func _apply_enemy_damage(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus) -> void:
	var p := state.player
	if p.roll_iframe > 0.0:
		return      # 翻滚无敌帧：接触伤害直接跳过
	var wave_phase := state.phase == GameState.Phase.WAVE
	var wall_radius := 12.0
	if not state.wall.is_empty():
		wall_radius = (state.wall[0] as GameState.WallSegment).center.length()
	var incoming := 0.0
	for e in state.enemies:
		if not e.alive:
			continue
		if wave_phase and e.pos.length() > wall_radius - 0.5:
			continue      # 墙外敌人只拆墙，不越过墙打人
		if e.pos.distance_to(p.pos) <= 1.5:
			incoming += e.dmg * dt / maxf(0.2, e.interval)
	if incoming <= 0.0:
		return
	p.hp -= incoming
	p.hurt_flash = 0.15
	bus.emit(EventBus.PLAYER_HURT, {"hp": p.hp, "dmg": incoming})
	if p.hp <= 0.0:
		p.hp = 0.0
		p.alive = false
		p.death_count += 1
		state.stats["deaths"] = int(state.stats["deaths"]) + 1
		var base := float(state.player.death_count - 1)
		p.respawn_timer = minf(
			cfg.num("player", "respawn_base", 8.0) + cfg.num("player", "respawn_step", 6.0) * base,
			cfg.num("player", "respawn_cap", 24.0))
		bus.emit(EventBus.PLAYER_DIED, {"death_count": p.death_count,
			"timer": p.respawn_timer})


static func _respawn(state: GameState, cfg: ConfigDB, bus: EventBus) -> void:
	var p := state.player
	p.pos = GameState.spawn_point(cfg)
	p.hp = p.max_hp
	p.alive = true
	p.respawn_timer = 0.0
	bus.emit(EventBus.PLAYER_RESPAWNED, {"pos": p.pos})
