class_name BuildSystem
extends RefCounted
## 建造系统（2026-11-10）：木箱 / 背包 / 城墙段 / 炮台。
##
## 边界：
##   - 只读写 GameState 的建造字段；不碰 view/ui。
##   - 城墙段仍以 GameState.wall 为战斗/存档单源，本系统只负责「新建/拆除」。
##   - 木箱的 25 格仓库与背包/资源系统联动：资源与物品都能存取，摧毁时按格掉落。
##
## 数值来源全部在 data/buildings.json；本文件不出现任何价格/HP 常量。

const IDS := ["crate", "backpack", "wall", "cannon"]
const RESOURCE_KINDS := ["coin", "brick", "metal", "ammo"]


# ---------------------------------------------------------------- 查询与计价

static func count_of(state: GameState, id: String) -> int:
	if id == "backpack":
		return state.backpack_built
	if id == "wall":
		return state.wall_built_this_wave
	var n := 0
	for b in state.buildings:
		if b.kind == id:
			n += 1
	return n


## 下一个要买的序号：木箱优先复用被摧毁的序号（重建不二次涨价）；
## 炮台/背包只增不减；城墙固定价，序号只用于「本波第几段」。
static func next_index(state: GameState, id: String) -> int:
	match id:
		"crate":
			if not state.crate_free_indices.is_empty():
				var arr := state.crate_free_indices.duplicate()
				arr.sort()
				return int(arr[0])
			return state.crate_next_index
		"cannon":
			return state.cannon_next_index
		"backpack":
			return state.backpack_built + 1
		"wall":
			return state.wall_built_this_wave + 1
	return 1


static func cost_for(state: GameState, cfg: ConfigDB, id: String) -> Dictionary:
	var cost := cfg.building_cost_at(id, next_index(state, id))
	if cost.is_empty():
		return {}
	cost["id"] = id
	return cost


static func cap_reason(state: GameState, cfg: ConfigDB, id: String) -> String:
	var def := cfg.building_def(id)
	if def.is_empty():
		return "未知建造物"
	var max_count := int(def.get("max_count", 0))
	if max_count > 0:
		var n := count_of(state, id)
		if n >= max_count:
			return "已达上限（%d/%d）" % [n, max_count]
	var per_wave := int(def.get("max_per_wave", 0))
	if per_wave > 0 and state.wall_built_this_wave >= per_wave:
		return "本波城墙段已建满（%d/%d）" % [state.wall_built_this_wave, per_wave]
	return ""


## 资源差多少：返回第一个不够的资源；全够返回空串。
static func afford_reason(state: GameState, cost: Dictionary) -> String:
	if cost.is_empty():
		return "价格缺失"
	if state.coin < int(cost.get("coin", 0)):
		return "金币不足（还差 %d）" % (int(cost.get("coin", 0)) - state.coin)
	if state.brick < int(cost.get("brick", 0)):
		return "砖块不足（还差 %d）" % (int(cost.get("brick", 0)) - state.brick)
	if state.metal < int(cost.get("metal", 0)):
		return "金属不足（还差 %d）" % (int(cost.get("metal", 0)) - state.metal)
	if state.ammo < int(cost.get("ammo", 0)):
		return "弹药不足（还差 %d）" % (int(cost.get("ammo", 0)) - state.ammo)
	return ""


# ---------------------------------------------------------------- 放置规则

## 只判位置/阶段/上限，不判资源（HUD 的悬停提示复用这一套，避免两处规则漂移）。
static func placement_reason(state: GameState, cfg: ConfigDB, id: String, pos: Vector2) -> String:
	if state.phase != GameState.Phase.BUILD:
		return "建设期才能建造"
	var def := cfg.building_def(id)
	if def.is_empty():
		return "未知建造物"
	var cap := cap_reason(state, cfg, id)
	if cap != "":
		return cap
	match String(def.get("placement", "city")):
		"self":
			return ""
		"ring":
			return _wall_place_reason(state, cfg, pos)
		_:
			return _city_place_reason(state, cfg, id, pos)


static func _city_place_reason(state: GameState, cfg: ConfigDB, id: String, pos: Vector2) -> String:
	var crystal_r := cfg.num("world", "crystal_radius", 4.0)
	if pos.length() < crystal_r + cfg.build_rule("crystal_margin", 1.5):
		return "离水晶太近"
	var wall_r := cfg.num("world", "wall_radius", 18.0)
	if pos.length() > wall_r - cfg.build_rule("city_margin", 2.0):
		return "只能建在城墙内"
	var def := cfg.building_def(id)
	var rr := GameState.footprint_radius(def)
	if state.wall_segment_at(pos, maxf(1.5, rr + cfg.build_rule("wall_clearance", 0.9)), true) >= 0:
		return "与城墙重叠"
	for b in state.buildings:
		var br := GameState.footprint_radius(cfg.building_def(b.kind))
		if pos.distance_to(b.pos) < rr + br + 0.2:
			return "与其他建造物重叠"
	return ""


static func _wall_place_reason(state: GameState, cfg: ConfigDB, pos: Vector2) -> String:
	if pos.length() < cfg.num("world", "crystal_radius", 4.0) + 6.0:
		return "离水晶太近"
	# 自由建造：所有建造物（含城墙段）都限定在城墙圈内，不再允许建到外圈 46m
	if pos.length() > cfg.num("world", "wall_radius", 18.0) - cfg.build_rule("city_margin", 2.0):
		return "只能建在城墙内"
	for seg in state.wall:
		if state.dist_to_wall(pos, seg) < 2.0:
			return "这里已有城墙"
	var wall_def := cfg.building_def("wall")
	var wr := GameState.footprint_radius(wall_def)
	for b in state.buildings:
		var br := GameState.footprint_radius(cfg.building_def(b.kind))
		if pos.distance_to(b.pos) < wr + br + 1.0:
			return "与其他建造物重叠"
	return ""


## 完整可建造判定：阶段 → 上限 → 位置 → 资源。
static func can_build(state: GameState, cfg: ConfigDB, id: String, pos: Vector2 = Vector2.ZERO) -> Dictionary:
	var cost := cost_for(state, cfg, id)
	if cost.is_empty():
		return {"ok": false, "reason": "未知建造物", "cost": cost}
	var reason := placement_reason(state, cfg, id, pos)
	if reason != "":
		return {"ok": false, "reason": reason, "cost": cost}
	var afford := afford_reason(state, cost)
	if afford != "":
		return {"ok": false, "reason": afford, "cost": cost}
	return {"ok": true, "reason": "", "cost": cost}


# ---------------------------------------------------------------- 建造

static func build(state: GameState, cfg: ConfigDB, bus: EventBus, id: String, pos: Vector2 = Vector2.ZERO) -> bool:
	var check := can_build(state, cfg, id, pos)
	if not bool(check["ok"]):
		bus.emit(EventBus.NOTICE, {"text": str(check["reason"])})
		return false
	var cost: Dictionary = check["cost"]
	for k in ["coin", "brick", "metal", "ammo"]:
		InventorySystem.spend(state, k, int(cost.get(k, 0)))

	var def := cfg.building_def(id)
	var label := ""
	match id:
		"backpack":
			state.backpack_built += 1
			var add_rows := int(def.get("add_rows", 2))
			state.bag_rows = state.base_bag_rows + state.backpack_built * add_rows
			state.bag_capacity = state.bag_cols * state.bag_rows
			InventorySystem.repack(state)
			label = "+%d 格（%d×%d）" % [int(def.get("add_slots", 10)),
				state.bag_cols, state.bag_rows]
		"wall":
			_append_wall(state, cfg, pos, cost)
			label = "第 %d 段" % (state.wall.size())
		_:
			_append_object(state, cfg, id, pos, cost)
			label = "第 %d 号" % int(cost.get("index", 1))
	bus.emit(EventBus.BUILDING_BUILT, {
		"id": id, "name": str(def.get("name", id)), "pos": pos,
		"cost": cost.duplicate(), "label": label,
	})
	return true


static func _append_object(state: GameState, cfg: ConfigDB, id: String, pos: Vector2,
		cost: Dictionary) -> void:
	var def := cfg.building_def(id)
	var b := GameState.BuildingState.new()
	state.building_seq += 1
	b.id = state.building_seq
	b.kind = id
	b.index = int(cost.get("index", 1))
	b.pos = pos
	b.max_hp = float(def.get("hp", 1.0))
	b.hp = b.max_hp
	b.paid_coin = int(cost.get("coin", 0))
	b.paid_brick = int(cost.get("brick", 0))
	b.paid_metal = int(cost.get("metal", 0))
	b.paid_ammo = int(cost.get("ammo", 0))
	b.built_wave = state.wave_index
	var storage: Dictionary = def.get("storage", {})
	if not storage.is_empty():
		b.stored_cols = int(storage.get("cols", 5))
		b.stored_rows = int(storage.get("rows", 5))
		var n := int(storage.get("slots", b.stored_cols * b.stored_rows))
		for i in range(n):
			b.stored.append({})
	state.buildings.append(b)
	# 序号提交：木箱优先消耗被摧毁的序号；炮台只增不减
	if id == "crate":
		if state.crate_free_indices.has(b.index):
			state.crate_free_indices.erase(b.index)
		else:
			state.crate_next_index = maxi(state.crate_next_index, b.index + 1)
	elif id == "cannon":
		state.cannon_next_index = maxi(state.cannon_next_index, b.index + 1)


static func _append_wall(state: GameState, cfg: ConfigDB, pos: Vector2, cost: Dictionary) -> void:
	var arc := deg_to_rad(cfg.num("world", "wall_arc_degrees", 150.0))
	var ring := maxf(1.0, cfg.num("world", "wall_radius", 18.0))
	var count := maxi(1, int(cfg.num("world", "wall_segments", 7)))
	var half_len := (arc * ring / float(count)) * 0.5 + 0.1
	var seg := GameState.WallSegment.new()
	seg.index = state.wall.size()
	seg.center = pos
	seg.tangent = pos.normalized().orthogonal()
	seg.half_len = half_len
	seg.max_hp = cfg.wall_segment_hp()
	seg.hp = seg.max_hp
	seg.level = 1
	seg.built = true
	seg.paid_coin = int(cost.get("coin", 0))
	seg.paid_brick = int(cost.get("brick", 0))
	seg.build_wave = state.wave_index
	state.wall.append(seg)
	state.wall_built_this_wave += 1


# ---------------------------------------------------------------- 拆除

## 光标下的可拆目标：先判建造物，再判墙段（默认 7 段不可拆）。
static func demolish_target(state: GameState, cfg: ConfigDB, pos: Vector2) -> Dictionary:
	var best: GameState.BuildingState = null
	var best_d := 1e9
	for b in state.buildings:
		var rr := GameState.footprint_radius(cfg.building_def(b.kind)) + 0.6
		var d: float = pos.distance_to(b.pos)
		if d <= rr and d < best_d:
			best_d = d
			best = b
	if best != null:
		return {"kind": "building", "id": best.id}
	var wi := state.wall_segment_at(pos, 2.5, true)
	if wi >= 0:
		return {"kind": "wall", "index": wi}
	return {}


static func demolish(state: GameState, cfg: ConfigDB, bus: EventBus, pos: Vector2) -> bool:
	if state.phase != GameState.Phase.BUILD:
		bus.emit(EventBus.NOTICE, {"text": "建设期才能拆除"})
		return false
	var target := demolish_target(state, cfg, pos)
	if target.is_empty():
		bus.emit(EventBus.NOTICE, {"text": "光标没指向可拆除的建造物"})
		return false
	var rate := cfg.build_rule("refund_rate", 0.5)
	if String(target["kind"]) == "building":
		var b := state.building_by_id(int(target["id"]))
		if b == null:
			return false
		var refund := {
			"coin": int(round(float(b.paid_coin) * rate)),
			"brick": int(round(float(b.paid_brick) * rate)),
			"metal": int(round(float(b.paid_metal) * rate)),
			"ammo": int(round(float(b.paid_ammo) * rate)),
		}
		for k in ["coin", "brick", "metal", "ammo"]:
			InventorySystem.grant(state, k, int(refund[k]))
		var dropped := 0
		if b.kind == "crate":
			dropped = _drop_contents(state, cfg, b)
			_release_crate_index(state, b.index)
		state.buildings.erase(b)
		for e in state.enemies:
			if e.target_building == b.id:
				e.target_building = -1
		bus.emit(EventBus.BUILDING_DEMOLISHED, {
			"id": b.id, "kind": b.kind, "name": str(cfg.building_def(b.kind).get("name", b.kind)),
			"pos": b.pos, "refund": refund, "drops": dropped,
		})
		return true
	# 墙段
	var index := int(target["index"])
	if index < 0 or index >= state.wall.size():
		return false
	var seg: GameState.WallSegment = state.wall[index]
	if not seg.built:
		bus.emit(EventBus.NOTICE, {"text": "初始城墙是地形，不能拆除"})
		return false
	var refund_wall := {
		"coin": int(round(float(seg.paid_coin) * rate)),
		"brick": int(round(float(seg.paid_brick) * rate)),
		"metal": 0, "ammo": 0,
	}
	InventorySystem.grant(state, "coin", int(refund_wall["coin"]))
	InventorySystem.grant(state, "brick", int(refund_wall["brick"]))
	var center := seg.center
	_remove_wall(state, index)
	# 注意：拆除不退「本波 1 段」名额，否则建了拆、拆了建可以绕过闸门。
	bus.emit(EventBus.BUILDING_DEMOLISHED, {
		"id": -1, "kind": "wall", "name": "城墙段", "pos": center,
		"refund": refund_wall, "drops": 0,
	})
	return true


static func _remove_wall(state: GameState, index: int) -> void:
	state.wall.remove_at(index)
	for i in range(state.wall.size()):
		state.wall[i].index = i
	for e in state.enemies:
		if e.target_wall == index:
			e.target_wall = -1
		elif e.target_wall > index:
			e.target_wall -= 1


# ---------------------------------------------------------------- 木箱仓库

static func crate_slot_count(b: GameState.BuildingState) -> int:
	return b.stored.size()


static func _empty_slot(b: GameState.BuildingState) -> int:
	for i in range(b.stored.size()):
		if (b.stored[i] as Dictionary).is_empty():
			return i
	return -1


## 存入背包物品：物品从 state.items 移入木箱，腾出背包格。
static func deposit_item(state: GameState, cfg: ConfigDB, bus: EventBus, crate_id: int, uid: int) -> bool:
	var crate := state.crate_by_id(crate_id)
	if crate == null:
		bus.emit(EventBus.NOTICE, {"text": "不在木箱存取范围"})
		return false
	var item := state.item_by_uid(uid)
	if item == null:
		return false
	var slot := _empty_slot(crate)
	if slot < 0:
		bus.emit(EventBus.NOTICE, {"text": "木箱已满（%d/%d）" % [crate.stored.size(), crate.stored.size()]})
		return false
	crate.stored[slot] = {"kind": "item", "item": InventorySystem.item_to_dict(item)}
	state.items.erase(item)
	if state.equipped.has(uid):
		state.equipped.erase(uid)
		InventorySystem.recompute(state)
	InventorySystem.repack(state)
	return true


static func withdraw_slot(state: GameState, cfg: ConfigDB, bus: EventBus, crate_id: int, slot: int) -> bool:
	var crate := state.crate_by_id(crate_id)
	if crate == null or slot < 0 or slot >= crate.stored.size():
		return false
	var data: Dictionary = crate.stored[slot]
	if data.is_empty():
		return false
	if String(data.get("kind", "")) == "item":
		var item := InventorySystem.item_from_dict(data.get("item", {}))
		if item == null or not InventorySystem.add_item(state, item):
			bus.emit(EventBus.NOTICE, {"text": "背包已满，先腾出格位"})
			return false
		crate.stored[slot] = {}
		return true
	var kind := String(data.get("kind", ""))
	var amount := int(data.get("amount", 0))
	if not (kind in RESOURCE_KINDS) or amount <= 0:
		crate.stored[slot] = {}
		return false
	_add_resource(state, kind, amount)
	crate.stored[slot] = {}
	return true


static func deposit_resource(state: GameState, cfg: ConfigDB, bus: EventBus, crate_id: int,
		kind: String, amount: int) -> bool:
	if not (kind in RESOURCE_KINDS) or amount <= 0:
		return false
	var crate := state.crate_by_id(crate_id)
	if crate == null:
		return false
	var have := _resource_amount(state, kind)
	var move := mini(amount, have)
	if move <= 0:
		return false
	var max_stack := int(cfg.build_rule("max_stack", 9999))
	for slot in crate.stored:
		var data: Dictionary = slot
		if data.is_empty() or String(data.get("kind", "")) != kind:
			continue
		if int(data.get("amount", 0)) + move > max_stack:
			continue
		data["amount"] = int(data.get("amount", 0)) + move
		_add_resource(state, kind, -move)
		return true
	var idx := _empty_slot(crate)
	if idx < 0:
		bus.emit(EventBus.NOTICE, {"text": "木箱已满（%d/%d）" % [crate.stored.size(), crate.stored.size()]})
		return false
	if move > max_stack:
		move = max_stack
	crate.stored[idx] = {"kind": kind, "amount": move}
	_add_resource(state, kind, -move)
	return true


static func withdraw_resource(state: GameState, cfg: ConfigDB, bus: EventBus, crate_id: int,
		kind: String, amount: int) -> int:
	if not (kind in RESOURCE_KINDS) or amount <= 0:
		return 0
	var crate := state.crate_by_id(crate_id)
	if crate == null:
		return 0
	for slot in crate.stored:
		var data: Dictionary = slot
		if data.is_empty() or String(data.get("kind", "")) != kind:
			continue
		var move := mini(amount, int(data.get("amount", 0)))
		if move <= 0:
			return 0
		data["amount"] = int(data.get("amount", 0)) - move
		_add_resource(state, kind, move)
		if int(data["amount"]) <= 0:
			slot.clear()
		return move
	return 0


static func _resource_amount(state: GameState, kind: String) -> int:
	match kind:
		"coin": return state.coin
		"brick": return state.brick
		"metal": return state.metal
		"ammo": return state.ammo
	return 0


static func _add_resource(state: GameState, kind: String, amount: int) -> void:
	# 资源唯一存储是背包：正数是入库、负数是扣除（仓库存入用负数）
	if amount < 0:
		InventorySystem.spend(state, kind, -amount)
	else:
		InventorySystem.grant(state, kind, amount)


# ---------------------------------------------------------------- 摧毁与掉落

static func damage_building(state: GameState, cfg: ConfigDB, bus: EventBus,
		b: GameState.BuildingState, dmg: float, source: String = "") -> void:
	if b == null or b.hp <= 0.0:
		return
	b.hp -= dmg
	# 接触伤害是逐帧的：不发事件、也不每帧闪白（HP 变红已足够表达）；
	# 离散攻击/自爆才发 BUILDING_HIT 并闪白。
	if source != "contact":
		b.hit_flash = 0.15
		bus.emit(EventBus.BUILDING_HIT, {"id": b.id, "kind": b.kind, "pos": b.pos, "dmg": dmg})
	if b.hp > 0.0:
		return
	b.hp = 0.0
	_destroy(state, cfg, bus, b, source)


static func _destroy(state: GameState, cfg: ConfigDB, bus: EventBus,
		b: GameState.BuildingState, source: String) -> void:
	var dropped := 0
	if b.kind == "crate":
		dropped = _drop_contents(state, cfg, b)
		_release_crate_index(state, b.index)
	elif b.kind == "cannon":
		var salvage := int(cfg.building_def("cannon").get("salvage_metal", 0))
		if salvage > 0:
			_spawn_drop(state, cfg, b.pos, "metal", salvage, {}, 0.0)
			dropped = 1
	state.buildings.erase(b)
	for e in state.enemies:
		if e.target_building == b.id:
			e.target_building = -1
	bus.emit(EventBus.BUILDING_DESTROYED, {
		"id": b.id, "kind": b.kind,
		"name": str(cfg.building_def(b.kind).get("name", b.kind)),
		"pos": b.pos, "drops": dropped, "source": source,
	})


## 箱内 100% 掉落：每格一个掉落物（资源堆 / 物品），1.5m 内随机散落，60s 后消失。
static func _drop_contents(state: GameState, cfg: ConfigDB, b: GameState.BuildingState) -> int:
	var n := 0
	for slot in b.stored:
		var data: Dictionary = slot
		if data.is_empty():
			continue
		var kind := String(data.get("kind", ""))
		if kind == "item":
			_spawn_drop(state, cfg, b.pos, "item", 1, data.get("item", {}), cfg.build_rule("drop_scatter", 1.5))
		else:
			_spawn_drop(state, cfg, b.pos, kind, int(data.get("amount", 0)), {},
				cfg.build_rule("drop_scatter", 1.5))
		n += 1
	b.stored.clear()
	return n


static func _spawn_drop(state: GameState, cfg: ConfigDB, origin: Vector2, kind: String,
		amount: int, item: Dictionary, scatter: float) -> GameState.DropState:
	var d := GameState.DropState.new()
	state.drop_seq += 1
	d.id = state.drop_seq
	var offset := Vector2.ZERO
	if scatter > 0.0:
		var angle := state.rng.randf_range(0.0, TAU)
		var radius := state.rng.randf_range(0.0, scatter)
		offset = Vector2(cos(angle), sin(angle)) * radius
	d.pos = origin + offset
	d.kind = kind
	d.amount = amount
	d.item = item.duplicate(true) if not item.is_empty() else {}
	d.ttl = cfg.build_rule("drop_ttl", 60.0)
	state.drops.append(d)
	return d


static func _release_crate_index(state: GameState, index: int) -> void:
	if not state.crate_free_indices.has(index):
		state.crate_free_indices.append(index)
		state.crate_free_indices.sort()


# ---------------------------------------------------------------- 炮台 / 接触伤害 / 掉落回收

static func step(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus) -> void:
	_update_near_crate(state, cfg)
	for b in state.buildings:
		b.hit_flash = maxf(0.0, b.hit_flash - dt)
	if state.phase == GameState.Phase.WAVE:
		_tick_towers(state, dt, cfg, bus)
		_tick_contact_damage(state, dt, cfg, bus)
	_tick_drops(state, dt, cfg, bus)


static func _update_near_crate(state: GameState, cfg: ConfigDB) -> void:
	state.near_crate = -1
	if not state.player.alive:
		return
	var radius := cfg.build_rule("storage_access_radius", 3.0)
	var best := radius
	for b in state.buildings:
		if b.kind != "crate":
			continue
		var d: float = state.player.pos.distance_to(b.pos)
		if d <= best:
			best = d
			state.near_crate = b.id


static func _tick_towers(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus) -> void:
	for b in state.buildings:
		if b.kind != "cannon":
			continue
		b.cooldown = maxf(0.0, b.cooldown - dt)
		if b.cooldown > 0.0:
			continue
		var attack: Dictionary = cfg.building_def("cannon").get("attack", {})
		var reach := float(attack.get("range", 16.0))
		var target: GameState.EnemyState = null
		var best_d := reach
		for e in state.enemies:
			if not e.alive:
				continue
			var d: float = b.pos.distance_to(e.pos)
			if d <= best_d:
				best_d = d
				target = e
		if target == null:
			continue
		var interval := maxf(0.1, float(attack.get("interval", 1.0)))
		b.cooldown = interval
		var dmg := float(attack.get("dps", 45.0)) * interval
		bus.emit(EventBus.BUILDING_SHOT, {"id": b.id, "from": b.pos, "to": target.pos})
		Combat.damage_enemy(state, target, dmg, bus)


## 行进碰撞：不主动追木箱的敌人贴上来也会磨血（仇根 0 = 只受碰撞/AOE 伤害）。
static func _tick_contact_damage(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus) -> void:
	for b in state.buildings.duplicate():
		if b.hp <= 0.0:
			continue
		var radius := GameState.footprint_radius(cfg.building_def(b.kind)) + 0.5
		for e in state.enemies:
			if not e.alive or e.target_building == b.id:
				continue
			if e.pos.distance_to(b.pos) > radius:
				continue
			var interval := maxf(0.2, e.interval)
			damage_building(state, cfg, bus, b, e.dmg * 0.25 * dt / interval, "contact")
			if b.hp <= 0.0:
				break


static func _tick_drops(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus) -> void:
	var pickup := cfg.build_rule("drop_pickup_radius", 1.2)
	for d in state.drops.duplicate():
		d.ttl -= dt
		if d.ttl <= 0.0:
			state.drops.erase(d)
			continue
		if not state.player.alive:
			continue
		if state.player.pos.distance_to(d.pos) > pickup:
			continue
		if d.kind == "item":
			var item := InventorySystem.item_from_dict(d.item)
			if item == null or not InventorySystem.add_item(state, item):
				if state.notice_timer <= 0.0:
					bus.emit(EventBus.NOTICE, {"text": "背包已满，掉落物留在原地"})
				continue          # 背包满：掉落物留在原地，腾出格位再回来捡
			state.drops.erase(d)
			bus.emit(EventBus.DROP_PICKED, {"kind": "item", "amount": 1,
				"name": item.name, "pos": d.pos})
		else:
			_add_resource(state, d.kind, d.amount)
			state.drops.erase(d)
			bus.emit(EventBus.DROP_PICKED, {"kind": d.kind, "amount": d.amount,
				"name": "", "pos": d.pos})


# ---------------------------------------------------------------- 修建造物

static func building_at_point(state: GameState, cfg: ConfigDB, pos: Vector2, tol: float = 1.2) -> GameState.BuildingState:
	var best: GameState.BuildingState = null
	var best_d := 1e9
	for b in state.buildings:
		var d: float = pos.distance_to(b.pos)
		if d <= GameState.footprint_radius(cfg.building_def(b.kind)) + tol and d < best_d:
			best_d = d
			best = b
	return best


## 锤子修建造物：优先修光标指着且够得着的，否则修身边最近的受伤目标。
static func repairable_at(state: GameState, cfg: ConfigDB, player_pos: Vector2,
		aim: Vector2, reach: float) -> GameState.BuildingState:
	var aimed := building_at_point(state, cfg, aim, 1.0)
	if aimed != null and aimed.hp < aimed.max_hp - 0.5 \
			and player_pos.distance_to(aimed.pos) <= reach:
		return aimed
	var best: GameState.BuildingState = null
	var best_d := reach
	for b in state.buildings:
		if b.hp >= b.max_hp - 0.5:
			continue
		var d: float = player_pos.distance_to(b.pos)
		if d <= best_d:
			best_d = d
			best = b
	return best


static func repair_building(state: GameState, bus: EventBus, b: GameState.BuildingState,
		heal: float) -> float:
	if b == null:
		return 0.0
	var before := b.hp
	b.hp = minf(b.max_hp, b.hp + heal)
	b.hit_flash = 0.1
	var actual := b.hp - before
	bus.emit(EventBus.BUILDING_REPAIRED, {"id": b.id, "kind": b.kind, "pos": b.pos, "heal": actual})
	return actual


# ---------------------------------------------------------------- 敌人仇恨

static func _enemy_inside_wall(state: GameState, cfg: ConfigDB, pos: Vector2) -> bool:
	var r := cfg.num("world", "wall_radius", 18.0)
	if not state.wall.is_empty():
		r = (state.wall[0] as GameState.WallSegment).center.length()
	return pos.length() < r - 0.4


## 已破口的敌人才会追城内建造物。每个敌人本波只掷一次骰：
## 木箱 0.3 ≈ 三成敌人会主动拆箱；炮台 0.6；掷失败则本波不再考虑建造物。
static func enemy_building_target(state: GameState, cfg: ConfigDB,
		e: GameState.EnemyState) -> GameState.BuildingState:
	if e.target_building == -2:
		return null
	if e.target_building >= 0:
		var current := state.building_by_id(e.target_building)
		if current != null and current.hp > 0.0:
			return current
		e.target_building = -1
	if not _enemy_inside_wall(state, cfg, e.pos):
		return null
	var best: GameState.BuildingState = null
	var best_d := 14.0
	for b in state.buildings:
		var d: float = e.pos.distance_to(b.pos)
		if d <= best_d:
			best_d = d
			best = b
	if best == null:
		return null
	var aggro := clampf(float(cfg.building_def(best.kind).get("aggro", 0.0)), 0.0, 1.0)
	if state.rng.randf() < aggro:
		e.target_building = best.id
		return best
	e.target_building = -2
	return null


static func advance_enemy_to_building(state: GameState, cfg: ConfigDB, bus: EventBus,
		e: GameState.EnemyState, b: GameState.BuildingState, dt: float) -> void:
	if b == null or b.hp <= 0.0:
		e.target_building = -1
		return
	var dist := e.pos.distance_to(b.pos)
	if dist <= 1.4:
		if e.kind == "bomber":
			e.phase = "fuse"
			e.fuse = 2.0
			return
		if e.atk_cd <= 0.0:
			e.atk_cd = e.interval
			bus.emit(EventBus.ENEMY_ATTACK, {"id": e.id, "kind": e.kind})
			damage_building(state, cfg, bus, b, e.dmg, "enemy")
		return
	var dir := b.pos - e.pos
	if dir.length() > 0.05:
		e.pos += dir.normalized() * e.speed * dt


static func damage_in_radius(state: GameState, cfg: ConfigDB, bus: EventBus,
		pos: Vector2, radius: float, dmg: float, source: String = "aoe") -> void:
	for b in state.buildings.duplicate():
		if b.hp <= 0.0:
			continue
		var r := radius + GameState.footprint_radius(cfg.building_def(b.kind))
		if pos.distance_to(b.pos) <= r:
			damage_building(state, cfg, bus, b, dmg, source)


# ---------------------------------------------------------------- UI 数据

## 建造面板的只读数据。selected/aim 是表现层状态，不由 core 持有。
static func ui_state(state: GameState, cfg: ConfigDB, selected: String,
		aim: Vector2, demolish_mode: bool) -> Dictionary:
	var items: Array = []
	for def in cfg.building_defs():
		var id := String(def.get("id", ""))
		var cost := cost_for(state, cfg, id)
		var cap := cap_reason(state, cfg, id)
		var afford := afford_reason(state, cost)
		var reason := ""
		if state.phase != GameState.Phase.BUILD:
			reason = "建设期才能建造"
		elif cap != "":
			reason = cap
		elif afford != "":
			reason = afford
		var max_count := int(def.get("max_count", 0))
		var per_wave := int(def.get("max_per_wave", 0))
		var limit_label := "不限"
		var count_label := "已建 %d · 不限" % count_of(state, id)
		if max_count > 0:
			limit_label = "%d" % max_count
			count_label = "%d/%d" % [count_of(state, id), max_count]
		elif per_wave > 0:
			limit_label = "每波 %d" % per_wave
			count_label = "本波 %d/%d" % [state.wall_built_this_wave, per_wave]
		items.append({
			"id": id,
			"name": str(def.get("name", id)),
			"tag": str(def.get("tag", "")),
			"desc": str(def.get("desc", "")),
			"effect": str(def.get("effect", "")),
			"placement": str(def.get("placement", "city")),
			"count": count_of(state, id),
			"max_count": max_count,
			"max_per_wave": per_wave,
			"limit_label": limit_label,
			"count_label": count_label,
			"cost": cost,
			"blocked": reason != "",
			"reason": reason,
			"affordable": afford == "",
		})
	var preview := ""
	if selected != "" and selected != "backpack":
		preview = placement_reason(state, cfg, selected, aim)
	var target := {}
	if demolish_mode:
		target = demolish_target(state, cfg, aim)
	return {
		"items": items,
		"selected": selected,
		"preview_reason": preview,
		"demolish_mode": demolish_mode,
		"demolish_target": target,
	}