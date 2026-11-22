class_name EconomySystem
extends RefCounted
## 经济系统：商店货架、购买、水晶升级、武器升级。
## 保留的核心玩法：前 4 格刚需固定（砖/金属/弹药/修复包），后 2 格轮换；刷新只重抽轮换格。
## v2.0 收敛：trait（词条）与 attachment（配件）不在核心里实现，货架池只保留可直接结算的动作。

## 刚需位：前 5 格固定（2026-11-09 起加了「轻弩」，否则副枪槽没有任何获取途径）。
## 注意：新增 SKU 必须同时进 FIXED_KEYS 或 ROTATION_POOL，否则配了表也永远不出现（R-3 同类问题）。
const WEAPON_KEYS := ["crossbow", "light_crossbow", "longsword", "rifle", "pistol", "rpg"]
const FIXED_KEYS := ["brick_pack", "metal_pack", "ammo_pack", "repair_pack"] + WEAPON_KEYS
const ROTATION_POOL := ["ammo_discount", "trait_common", "bag_upgrade"]


static func roll_shop(state: GameState, cfg: ConfigDB) -> void:
	state.shop_stock.clear()
	for row in cfg.shop:
		if str(row["key"]) in FIXED_KEYS:
			var unlock := int(row.get("unlock_wave", 1))
			state.shop_stock.append({
				"key": row["key"], "name": row["name"],
				"price_coin": int(row["price_coin"]), "price_metal": int(row["price_metal"]),
				"limit": int(row.get("limit", 1)), "sold": 0,
				"action": row["action"], "amount": row.get("amount", 0),
				"locked": state.wave_index < unlock, "unlock_wave": unlock,
			})
	_fill_rotation(state, cfg)


static func _fill_rotation(state: GameState, cfg: ConfigDB) -> void:
	while state.shop_stock.size() < FIXED_KEYS.size() + 1:
		var pick: Variant = _pick_rotation(state, cfg)
		if pick == null:
			break
		state.shop_stock.append(pick)


static func _pick_rotation(state: GameState, cfg: ConfigDB) -> Variant:
	var candidates: Array = []
	for row in cfg.shop:
		if not (str(row["key"]) in ROTATION_POOL):
			continue
		if state.wave_index < int(row.get("unlock_wave", 1)):
			continue
		# 扩容背包只卖一次
		if str(row["key"]) == "bag_upgrade" and state.backpack_upgraded:
			continue
		var taken := false
		for slot in state.shop_stock:
			if str(slot["key"]) == str(row["key"]):
				taken = true
				break
		if taken:
			continue
		candidates.append(row)
	if candidates.is_empty():
		return null
	var row: Dictionary = candidates[state.rng.randi_range(0, candidates.size() - 1)]
	return {
		"key": row["key"], "name": row["name"],
		"price_coin": int(row["price_coin"]), "price_metal": int(row["price_metal"]),
		"limit": int(row.get("limit", 1)), "sold": 0,
		"action": row["action"], "amount": row.get("amount", 0),
		"locked": false,
	}


static func refresh(state: GameState, cfg: ConfigDB, bus: EventBus) -> bool:
	if state.shop_refresh_used:
		bus.emit(EventBus.NOTICE, {"text": "本波已刷新过"})
		return false
	if state.coin < 40:
		bus.emit(EventBus.NOTICE, {"text": "金币不足（刷新 40）"})
		return false
	InventorySystem.spend(state, "coin", 40)
	state.shop_refresh_used = true
	var kept: Array = []
	for slot in state.shop_stock:
		if str(slot["key"]) in FIXED_KEYS:
			kept.append(slot)
	state.shop_stock = kept
	_fill_rotation(state, cfg)
	bus.emit(EventBus.PURCHASE, {"key": "refresh"})
	return true


static func buy(state: GameState, cfg: ConfigDB, bus: EventBus, index: int) -> bool:
	if state.phase != GameState.Phase.BUILD:
		return false
	if index < 0 or index >= state.shop_stock.size():
		return false
	var slot: Dictionary = state.shop_stock[index]
	if bool(slot.get("locked", false)):
		bus.emit(EventBus.NOTICE, {"text": "下波解锁"})
		return false
	if int(slot["sold"]) >= int(slot["limit"]):
		bus.emit(EventBus.NOTICE, {"text": "已售罄"})
		return false
	# 背包已满时先拒绝，绝不能扣钱（验收标准 §7.5）
	if String(slot["action"]) == "trait" \
			and InventorySystem.bag_used_cells(state) >= state.bag_capacity:
		bus.emit(EventBus.NOTICE, {"text": "背包已满，先卖出或装备"})
		return false
	if String(slot["action"]) == "weapon":
		var id := str(slot["key"])
		if id not in WEAPON_KEYS:
			return false
		if state.player.owned_weapons.has(id) or state.player.slots.has(id):
			bus.emit(EventBus.NOTICE, {"text": "已拥有该武器"})
			return false

	var price_coin := int(slot["price_coin"])
	var price_metal := int(slot["price_metal"])
	if state.coin < price_coin or state.metal < price_metal:
		bus.emit(EventBus.NOTICE, {"text": "资源不足"})
		return false
	InventorySystem.spend(state, "coin", price_coin)
	InventorySystem.spend(state, "metal", price_metal)
	slot["sold"] = int(slot["sold"]) + 1
	match str(slot["action"]):
		"brick": InventorySystem.grant(state, "brick", int(slot["amount"]))
		"metal": InventorySystem.grant(state, "metal", int(slot["amount"]))
		"ammo": InventorySystem.grant(state, "ammo", int(slot["amount"]))
		"trait":
			var item := InventorySystem.roll_item(state, cfg)
			if InventorySystem.add_item(state, item):
				bus.emit(EventBus.ITEM_GAINED, {"name": item.name, "tier": item.tier, "desc": item.desc})
		"repair":
			var pct := float(slot["amount"])
			for seg in state.wall:
				if not seg.breached:
					seg.hp = minf(seg.max_hp, seg.hp + seg.max_hp * pct)
		"bag":
			# 背包扩容：10 格 -> 18 格，一次性替换
			if InventorySystem.resize_bag(state, InventorySystem.BAG_COLS_UPGRADED,
					InventorySystem.BAG_ROWS_UPGRADED):
				state.backpack_upgraded = true
				bus.emit(EventBus.NOTICE, {"text": "背包已扩容到 6×3（18 格）"})
			else:
				bus.emit(EventBus.NOTICE, {"text": "背包扩容失败"})
		"weapon":
			var weapon_id := str(slot["key"])
			if not state.player.owned_weapons.has(weapon_id):
				state.player.owned_weapons.append(weapon_id)
			state.player.weapon_levels[weapon_id] = maxi(1, int(state.player.weapon_levels.get(weapon_id, 1)))
			var equipped_slot := equip_weapon(state, weapon_id)
			bus.emit(EventBus.NOTICE, {"text": "已永久拥有并装备「%s」到槽 %d" % [str(slot["name"]), equipped_slot + 1]})
		_:
			pass
	bus.emit(EventBus.PURCHASE, {"key": slot["key"], "name": slot["name"]})
	return true


## 第一个空着的枪槽；没有则 -1。
static func free_gun_slot(state: GameState) -> int:
	for i in range(mini(2, state.player.slots.size())):
		if str(state.player.slots[i]) == "":
			return i
	return -1


## 将已拥有武器装入指定快捷槽；无空槽时替换该槽现有武器。
static func equip_weapon(state: GameState, weapon_id: String, target_slot: int = -1) -> int:
	if not (weapon_id in ["crossbow", "light_crossbow", "longsword", "rifle", "pistol", "rpg"]):
		return -1
	if not state.player.owned_weapons.has(weapon_id):
		return -1
	var target := target_slot
	if target < 0:
		target = free_gun_slot(state)
		if target < 0:
			target = clampi(state.player.active_slot, 0, 1)
	if target < 0 or target > 1:
		return -1
	for i in range(mini(2, state.player.slots.size())):
		if i != target and str(state.player.slots[i]) == weapon_id:
			state.player.slots[i] = str(state.player.slots[target])
	state.player.slots[target] = weapon_id
	state.player.active_slot = target
	return target


static func equip_owned(state: GameState, weapon_id: String, target_slot: int, bus: EventBus) -> bool:
	if state.phase != GameState.Phase.BUILD or not state.player.owned_weapons.has(weapon_id):
		return false
	var target := equip_weapon(state, weapon_id, target_slot)
	if target < 0:
		return false
	bus.emit(EventBus.NOTICE, {"text": "已装备「%s」到槽 %d" % [weapon_name(weapon_id), target + 1]})
	bus.emit(EventBus.PURCHASE, {"key": "weapon_equip", "id": weapon_id, "slot": target})
	return true


static func weapon_name(weapon_id: String) -> String:
	match weapon_id:
		"crossbow": return "弩"
		"light_crossbow": return "轻弩"
		"longsword": return "长剑"
		"rifle": return "步枪"
		"pistol": return "手枪"
		"rpg": return "火箭筒"
	return weapon_id


static func upgrade_crystal(state: GameState, cfg: ConfigDB, bus: EventBus) -> bool:
	if state.crystal_level >= 10:
		bus.emit(EventBus.NOTICE, {"text": "水晶已满级"})
		return false
	var next := cfg.crystal_row(state.crystal_level + 1)
	var cost_coin := int(next.get("cost_coin", 0))
	var cost_metal := int(next.get("cost_metal", 0))
	if state.coin < cost_coin or state.metal < cost_metal:
		bus.emit(EventBus.NOTICE, {"text": "升级资源不足"})
		return false
	InventorySystem.spend(state, "coin", cost_coin)
	InventorySystem.spend(state, "metal", cost_metal)
	state.crystal_level += 1
	bus.emit(EventBus.PURCHASE, {"key": "crystal_upgrade", "level": state.crystal_level})
	return true


static func upgrade_wall(state: GameState, cfg: ConfigDB, bus: EventBus, index: int) -> bool:
	if state.phase != GameState.Phase.BUILD:
		bus.emit(EventBus.NOTICE, {"text": "建设期才能升级城墙"})
		return false
	if index < 0 or index >= state.wall.size():
		return false
	var seg: GameState.WallSegment = state.wall[index]
	if seg.breached:
		bus.emit(EventBus.NOTICE, {"text": "破口需要先重建"})
		return false
	var max_level := int(cfg.num("wall_rules", "max_level", 3))
	if seg.level >= max_level:
		bus.emit(EventBus.NOTICE, {"text": "该段已满级"})
		return false
	var cost_brick := int(cfg.num("wall_rules", "upgrade_brick_cost", 20))
	var cost_coin := int(cfg.num("wall_rules", "upgrade_coin_cost", 80))
	if state.brick < cost_brick or state.coin < cost_coin:
		bus.emit(EventBus.NOTICE, {"text": "升级资源不足"})
		return false
	InventorySystem.spend(state, "brick", cost_brick)
	InventorySystem.spend(state, "coin", cost_coin)
	seg.level += 1
	seg.max_hp *= 1.35
	seg.hp = seg.max_hp
	bus.emit(EventBus.PURCHASE, {"key": "wall_upgrade", "index": index, "level": seg.level})
	return true


## 重建破口：整段重建（不是修血），砖 + 币。建设期与战斗期都能做——
## 战斗期这正是「墙塌了就地补一段」的操作，也是砖块最直观的用途。
static func rebuild_wall(state: GameState, cfg: ConfigDB, bus: EventBus, index: int) -> bool:
	if not (state.phase in [GameState.Phase.BUILD, GameState.Phase.WAVE]):
		bus.emit(EventBus.NOTICE, {"text": "建设期或战斗期才能重建城墙"})
		return false
	if index < 0 or index >= state.wall.size():
		return false
	var seg: GameState.WallSegment = state.wall[index]
	if not seg.breached:
		bus.emit(EventBus.NOTICE, {"text": "该段尚未破损"})
		return false
	var cost_brick := int(cfg.num("wall_rules", "rebuild_brick_cost", 30))
	var cost_coin := int(cfg.num("wall_rules", "rebuild_coin_cost", 150))
	if state.brick < cost_brick or state.coin < cost_coin:
		bus.emit(EventBus.NOTICE, {"text": "重建资源不足（%d 砖 · %d 金）" % [cost_brick, cost_coin]})
		return false
	InventorySystem.spend(state, "brick", cost_brick)
	InventorySystem.spend(state, "coin", cost_coin)
	seg.breached = false
	seg.hp = seg.max_hp
	seg.hit_flash = 0.2
	bus.emit(EventBus.PURCHASE, {"key": "wall_rebuild", "index": index})
	return true


## 新建一段城墙（2026-11-09 无限段 → 2026-11-10 改为「每波 1 段」）。
## 规则与造价统一由 BuildSystem 管；这里保留入口是为了旧调用方/测试不用改签名。
static func build_wall(state: GameState, cfg: ConfigDB, bus: EventBus, pos: Vector2) -> bool:
	return BuildSystem.build(state, cfg, bus, "wall", pos)


## 为什么这里不能建（空串 = 可以）。给 HUD 的建造提示复用同一套判定，避免两处规则漂移。
static func build_block_reason(state: GameState, cfg: ConfigDB, pos: Vector2) -> String:
	return BuildSystem.placement_reason(state, cfg, "wall", pos)


static func upgrade_weapon(state: GameState, cfg: ConfigDB, bus: EventBus, weapon_id: String) -> bool:
	var level := int(state.player.weapon_levels.get(weapon_id, 1))
	var next := cfg.weapon_level_row(weapon_id, level + 1)
	if next.is_empty() or int(next["level"]) <= level:
		bus.emit(EventBus.NOTICE, {"text": "已满级"})
		return false
	var cost_coin := int(next.get("cost_coin", 0))
	var cost_metal := int(next.get("cost_metal", 0))
	if state.coin < cost_coin or state.metal < cost_metal:
		bus.emit(EventBus.NOTICE, {"text": "升级资源不足"})
		return false
	InventorySystem.spend(state, "coin", cost_coin)
	InventorySystem.spend(state, "metal", cost_metal)
	state.player.weapon_levels[weapon_id] = level + 1
	bus.emit(EventBus.PURCHASE, {"key": "weapon_upgrade", "id": weapon_id, "level": level + 1})
	return true
