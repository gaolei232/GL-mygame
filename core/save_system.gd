class_name SaveSystem
extends RefCounted
## 存档（P0-9）：GameState ↔ JSON 字典。纯数据，不碰文件（文件 IO 在 app 层）。
##
## 口径：只在「没有敌人」的安全阶段落盘（SCOUT / BUILD / REWARD）。
## 这三处的敌人、箱子、生成队列要么为空、要么由系统重新生成，
## 所以不必序列化敌人——也就没有「读档后波次卡住」这类坑。
## 战斗期退出 = 回到本波最近的安全阶段（会重打这一波），这是有意的取舍。

const VERSION := 1
const SUPPORTED_PHASES := [
	GameState.Phase.SCOUT, GameState.Phase.BUILD, GameState.Phase.REWARD,
]


static func capture(state: GameState) -> Dictionary:
	var walls: Array = []
	for seg in state.wall:
		walls.append({
			"hp": seg.hp, "max_hp": seg.max_hp, "level": seg.level, "breached": seg.breached,
			# 几何也要存：玩家新建的墙段不在默认 7 段里
			"center": _v(seg.center), "tangent": _v(seg.tangent), "half_len": seg.half_len,
			"built": seg.built, "paid_coin": seg.paid_coin, "paid_brick": seg.paid_brick,
			"build_wave": seg.build_wave,
		})
	var items: Array = []
	for it in state.items:
		var row := InventorySystem.item_to_dict(it)
		row["count"] = it.count          # 资源堆叠数量（2026-11-15 背包化）
		items.append(row)
	var buildings: Array = []
	for b in state.buildings:
		buildings.append({
			"id": b.id, "kind": b.kind, "index": b.index, "pos": _v(b.pos),
			"hp": b.hp, "max_hp": b.max_hp, "stored": b.stored.duplicate(true),
			"stored_cols": b.stored_cols, "stored_rows": b.stored_rows,
			"paid_coin": b.paid_coin, "paid_brick": b.paid_brick,
			"paid_metal": b.paid_metal, "paid_ammo": b.paid_ammo,
			"built_wave": b.built_wave, "cooldown": b.cooldown,
		})
	var drops: Array = []
	for d in state.drops:
		drops.append({
			"id": d.id, "pos": _v(d.pos), "kind": d.kind, "amount": d.amount,
			"item": d.item.duplicate(true), "ttl": d.ttl,
		})
	return {
		"version": VERSION,
		"phase": state.phase,
		"wave_index": state.wave_index,
		"coin": state.coin, "brick": state.brick, "metal": state.metal, "ammo": state.ammo,
		"crystal": {
			"hp": state.crystal_hp, "max_hp": state.crystal_max_hp, "level": state.crystal_level,
		},
		"wall": walls,
		"player": {
			"pos": _v(state.player.pos), "hp": state.player.hp,
			"slots": state.player.slots.duplicate(), "owned_weapons": state.player.owned_weapons.duplicate(),
			"active_slot": state.player.active_slot,
			"weapon_levels": state.player.weapon_levels.duplicate(),
			"death_count": state.player.death_count,
		},
		"items": items,
		"equipped": state.equipped.duplicate(),
		"item_seq": state.item_seq,
		"bag_cols": state.bag_cols,
		"backpack_upgraded": state.backpack_upgraded,
		"buildings": buildings,
		"drops": drops,
		"backpack_built": state.backpack_built,
		"bag_rows": state.bag_rows,
		"crate_free_indices": state.crate_free_indices.duplicate(),
		"crate_next_index": state.crate_next_index,
		"cannon_next_index": state.cannon_next_index,
		"wall_built_this_wave": state.wall_built_this_wave,
		"building_seq": state.building_seq,
		"drop_seq": state.drop_seq,
		"theme": state.theme,
		"shop_stock": state.shop_stock.duplicate(true),
		"shop_refresh_used": state.shop_refresh_used,
		"stats": state.stats.duplicate(),
		"reward_choices": state.reward_choices.duplicate(true),
		# 64 位状态用字符串存：JSON 数字是 double，超过 2^53 会丢精度
		"seed": state.seed_value,
		"rng_state": str(state.rng.state),
	}


static func restore(state: GameState, cfg: ConfigDB, bus: EventBus, data: Dictionary) -> bool:
	if int(data.get("version", -1)) != VERSION:
		return false
	var phase := int(data.get("phase", -1))
	if not (phase in SUPPORTED_PHASES):
		return false
	var saved_choices: Array = data.get("reward_choices", [])
	if phase == GameState.Phase.REWARD and saved_choices.is_empty():
		return false
	var walls: Array = data.get("wall", [])
	if walls.is_empty():
		return false

	# setup() 负责重建基线（墙几何、资源初值、rng），随后逐字段覆盖
	state.setup(cfg, int(data.get("seed", 0)))
	# 读档可能发生在同一进程里（战斗中退出 → 主菜单继续），必须清掉残留的战场对象
	state.enemies.clear()
	state.loot_boxes.clear()
	state.spawn_queue.clear()
	state.summon_pending.clear()
	state.wave_elapsed = 0.0
	state.wave_spawned = 0
	state.wave_killed = 0
	state.wave_total = 0
	state.phase = phase
	state.phase_time = 0.0
	state.phase_duration = 0.0
	if phase == GameState.Phase.SCOUT:
		state.phase_duration = float(cfg.num("phases", "scout_seconds", 90.0))
	state.wave_index = maxi(1, int(data.get("wave_index", 1)))

	state.coin = int(data.get("coin", 0))
	state.brick = int(data.get("brick", 0))
	state.metal = int(data.get("metal", 0))
	state.ammo = int(data.get("ammo", 0))

	var cry: Dictionary = data.get("crystal", {})
	state.crystal_max_hp = float(cry.get("max_hp", state.crystal_max_hp))
	state.crystal_hp = clampf(float(cry.get("hp", state.crystal_max_hp)), 0.0, state.crystal_max_hp)
	state.crystal_level = int(cry.get("level", 1))

	# 墙段可以无限新建（2026-11-09），所以按存档里的几何逐段重建，而不是套用默认 7 段
	var defaults: Array = state.wall.duplicate()
	var fallback_hp := cfg.num("world", "wall_hp_total", 85000.0) \
		/ maxf(1.0, cfg.num("world", "wall_segments", 7))
	state.wall.clear()
	for i in range(walls.size()):
		var row: Dictionary = walls[i]
		var seg := GameState.WallSegment.new()
		seg.index = i
		if row.has("center") and row.has("tangent"):
			seg.center = _vec(row["center"], Vector2.ZERO)
			seg.tangent = _vec(row["tangent"], Vector2.RIGHT)
			seg.half_len = float(row.get("half_len", 4.0))
		elif i < defaults.size():
			var d: GameState.WallSegment = defaults[i]
			seg.center = d.center
			seg.tangent = d.tangent
			seg.half_len = d.half_len
		else:
			return false                       # 旧档且段数超出默认墙圈：无法复原几何
		seg.max_hp = float(row.get("max_hp", fallback_hp))
		seg.hp = clampf(float(row.get("hp", seg.max_hp)), 0.0, seg.max_hp)
		seg.level = int(row.get("level", 1))
		seg.breached = bool(row.get("breached", seg.hp <= 0.0))
		# 旧档（2026-11-09 无限段）没有 built/paid 字段：默认 7 段之后视为自建，
		# 否则玩家在旧档里建的墙会突然变成不可拆的「地形」。
		seg.built = bool(row.get("built", i >= int(cfg.num("world", "wall_segments", 7))))
		seg.paid_coin = int(row.get("paid_coin",
			cfg.wall_build_coin_cost() if seg.built else 0))
		seg.paid_brick = int(row.get("paid_brick", 20 if seg.built else 0))
		seg.build_wave = int(row.get("build_wave", 0))
		state.wall.append(seg)

	var p: Dictionary = data.get("player", {})
	state.player.pos = _vec(p.get("pos", {}), state.player.pos)
	state.player.hp = clampf(float(p.get("hp", state.player.max_hp)), 1.0, state.player.max_hp)
	state.player.alive = true
	state.player.respawn_timer = 0.0
	var slots: Array = p.get("slots", state.player.slots)
	if slots.size() >= 2:
		state.player.slots = [str(slots[0]), str(slots[1])]
	state.player.active_slot = clampi(int(p.get("active_slot", 0)), 0, 3)
	var lv: Dictionary = p.get("weapon_levels", {})
	for k in lv.keys():
		state.player.weapon_levels[str(k)] = int(lv[k])
	# Older saves have no ownership field; equipped guns are the source of truth.
	state.player.owned_weapons.clear()
	var valid_weapon_ids := ["crossbow", "light_crossbow", "longsword", "rifle", "pistol", "rpg"]
	for weapon_id in p.get("owned_weapons", []):
		var id := str(weapon_id)
		if id in valid_weapon_ids and not state.player.owned_weapons.has(id):
			state.player.owned_weapons.append(id)
	for weapon_id in state.player.slots:
		var id := str(weapon_id)
		if id in valid_weapon_ids and not state.player.owned_weapons.has(id):
			state.player.owned_weapons.append(id)
		if id in valid_weapon_ids and not state.player.weapon_levels.has(id):
			state.player.weapon_levels[id] = 1
	state.player.death_count = int(p.get("death_count", 0))

	state.items.clear()
	for row in data.get("items", []):
		var it := InventorySystem.item_from_dict(row)
		if it != null:
			it.count = int(row.get("count", 0))     # 资源堆叠数量
			state.items.append(it)
	state.equipped.clear()
	for uid in data.get("equipped", []):
		if state.item_by_uid(int(uid)) != null:
			state.equipped.append(int(uid))
	state.item_seq = int(data.get("item_seq", state.items.size()))
	# 背包扩容：旧档没有这些字段 → backpack_built=0，退回基础 5×2
	state.backpack_built = maxi(0, int(data.get("backpack_built", 0)))
	state.backpack_upgraded = bool(data.get("backpack_upgraded", false))
	var add_rows := int(cfg.building_def("backpack").get("add_rows", 2))
	state.bag_cols = maxi(InventorySystem.BAG_COLS, int(data.get("bag_cols", InventorySystem.BAG_COLS)))
	state.bag_rows = maxi(int(data.get("bag_rows", 0)),
		state.base_bag_rows + state.backpack_built * add_rows)
	state.bag_capacity = state.bag_cols * state.bag_rows
	# 资源唯一存储是背包：载入后必须重算聚合值，否则旧档的 coin/ammo 会与背包不一致。
	# 旧档（没有资源堆）用存档里的计数器兜底灌一次。
	if InventorySystem.total_of(state, "coin") + InventorySystem.total_of(state, "ammo") \
			+ InventorySystem.total_of(state, "brick") + InventorySystem.total_of(state, "metal") <= 0 \
			and (state.coin > 0 or state.ammo > 0 or state.brick > 0 or state.metal > 0):
		InventorySystem.seed_resources(state)
	InventorySystem.refresh_totals(state)
	InventorySystem.repack(state)

	# 建造物与掉落物：旧档没有则为空（向后兼容）
	state.buildings.clear()
	for row in data.get("buildings", []):
		var kind := str(row.get("kind", ""))
		var def := cfg.building_def(kind)
		if def.is_empty():
			continue
		var b := GameState.BuildingState.new()
		b.id = int(row.get("id", 0))
		b.kind = kind
		b.index = int(row.get("index", 1))
		b.pos = _vec(row.get("pos", {}), Vector2.ZERO)
		b.max_hp = float(row.get("max_hp", def.get("hp", 1.0)))
		b.hp = clampf(float(row.get("hp", b.max_hp)), 0.0, b.max_hp)
		b.stored_cols = int(row.get("stored_cols", 5))
		b.stored_rows = int(row.get("stored_rows", 5))
		b.paid_coin = int(row.get("paid_coin", 0))
		b.paid_brick = int(row.get("paid_brick", 0))
		b.paid_metal = int(row.get("paid_metal", 0))
		b.paid_ammo = int(row.get("paid_ammo", 0))
		b.built_wave = int(row.get("built_wave", state.wave_index))
		b.cooldown = float(row.get("cooldown", 0.0))
		var stored: Array = row.get("stored", [])
		for slot in stored:
			b.stored.append((slot as Dictionary).duplicate(true) if slot is Dictionary else {})
		var storage_slots := int(def.get("storage", {}).get("slots", 0))
		while b.stored.size() < storage_slots:
			b.stored.append({})
		if b.stored.size() > storage_slots and storage_slots > 0:
			b.stored.resize(storage_slots)
		state.buildings.append(b)
		state.building_seq = maxi(state.building_seq, b.id)
	state.drops.clear()
	for row in data.get("drops", []):
		var d := GameState.DropState.new()
		d.id = int(row.get("id", 0))
		d.pos = _vec(row.get("pos", {}), Vector2.ZERO)
		d.kind = str(row.get("kind", "coin"))
		d.amount = int(row.get("amount", 0))
		var item_row: Variant = row.get("item", {})
		d.item = (item_row as Dictionary).duplicate(true) if item_row is Dictionary else {}
		d.ttl = float(row.get("ttl", 60.0))
		state.drops.append(d)
		state.drop_seq = maxi(state.drop_seq, d.id)
	state.crate_free_indices.clear()
	for idx in data.get("crate_free_indices", []):
		var v := int(idx)
		if v > 0 and not state.crate_free_indices.has(v):
			state.crate_free_indices.append(v)
	state.crate_next_index = maxi(1, int(data.get("crate_next_index", 1)))
	state.cannon_next_index = maxi(1, int(data.get("cannon_next_index", 1)))
	# 防御性修复：空闲序号不能与存活木箱/炮台冲突，next 不能落在已用序号上
	for b in state.buildings:
		if b.kind == "crate":
			state.crate_free_indices.erase(b.index)
			state.crate_next_index = maxi(state.crate_next_index, b.index + 1)
		elif b.kind == "cannon":
			state.cannon_next_index = maxi(state.cannon_next_index, b.index + 1)
	state.wall_built_this_wave = maxi(0, int(data.get("wall_built_this_wave", 0)))
	state.building_seq = maxi(state.building_seq, int(data.get("building_seq", 0)))
	state.drop_seq = maxi(state.drop_seq, int(data.get("drop_seq", 0)))
	InventorySystem.repack(state)      # 背包按格占位：读档后要重排一次才有 layout
	InventorySystem.recompute(state)

	state.theme = str(data.get("theme", ""))
	state.shop_refresh_used = bool(data.get("shop_refresh_used", false))
	state.shop_stock.clear()
	for row in data.get("shop_stock", []):
		state.shop_stock.append({
			"key": str(row.get("key", "")), "name": str(row.get("name", "")),
			"price_coin": int(row.get("price_coin", 0)), "price_metal": int(row.get("price_metal", 0)),
			"limit": int(row.get("limit", 1)), "sold": int(row.get("sold", 0)),
			"action": str(row.get("action", "")), "amount": row.get("amount", 0),
			"locked": bool(row.get("locked", false)),
		})
	var st: Dictionary = data.get("stats", {})
	state.stats = {
		"shots": int(st.get("shots", 0)), "hits": int(st.get("hits", 0)),
		"kills": int(st.get("kills", 0)), "deaths": int(st.get("deaths", 0)),
		"repair_hp": float(st.get("repair_hp", 0.0)),
	}
	# state 为 0 的 xorshift 会永远输出 0，宁可用 seed 重新起一条序列
	var rng_state := int(str(data.get("rng_state", "0")))
	if rng_state != 0:
		state.rng.state = rng_state

	# 阶段副作用按「进入该阶段」的规则补一遍，避免读档后缺东西
	match phase:
		GameState.Phase.SCOUT:
			ScoutSystem.begin(state, cfg, bus)          # 箱子/追兵重新生成
		GameState.Phase.BUILD:
			if state.shop_stock.is_empty():
				EconomySystem.roll_shop(state, cfg)
			GuardSystem.refresh(state, cfg, bus)
		GameState.Phase.REWARD:
			state.reward_choices = saved_choices.duplicate(true)
	return true


static func _v(v: Vector2) -> Dictionary:
	return {"x": v.x, "y": v.y}


static func _vec(d: Dictionary, fallback: Vector2) -> Vector2:
	if d.is_empty():
		return fallback
	return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))