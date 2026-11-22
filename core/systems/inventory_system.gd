class_name InventorySystem
extends RefCounted
## 背包与养成（P1-4）：稀有度抽取、装备/卸下/卖出、装备加成聚合。
## 边界：只读写 GameState 的物品字段与 mods；不碰战斗判定，战斗侧只读 state.mods。

## 抽取一件物品：稀有度按波次权重，数值 = 基础值 × 稀有度倍率
static func roll_item(state: GameState, cfg: ConfigDB, tier_override: int = -1) -> GameState.Item:
	var tier := tier_override if tier_override >= 0 else _roll_tier(state, cfg)
	var rarity := cfg.rarity_row(tier)
	var pool := cfg.item_defs()
	if pool.is_empty():
		return null
	var row: Dictionary = pool[state.rng.randi_range(0, pool.size() - 1)]
	var mult := float(rarity.get("mult", 1.0))

	var item := GameState.Item.new()
	state.item_seq += 1
	item.uid = state.item_seq
	item.kind = String(row.get("kind", "trait"))
	item.def_id = String(row.get("id", ""))
	item.name = String(row.get("name", "词条"))
	item.tier = tier
	item.stat = String(row.get("stat", "dmg"))
	item.value = float(row.get("base", 0.0)) * mult
	item.desc = _describe(item)
	item.sell = int(rarity.get("sell", 40))
	return item


## 物品 ↔ 字典：木箱存储、掉落物与存档共用，避免三处各写一遍字段。
static func item_to_dict(item: GameState.Item) -> Dictionary:
	if item == null:
		return {}
	return {
		"uid": item.uid, "kind": item.kind, "def_id": item.def_id, "name": item.name,
		"tier": item.tier, "stat": item.stat, "value": item.value, "desc": item.desc,
		"sell": item.sell,
	}


static func item_from_dict(row: Dictionary) -> GameState.Item:
	if row.is_empty():
		return null
	var item := GameState.Item.new()
	item.uid = int(row.get("uid", 0))
	item.kind = str(row.get("kind", "trait"))
	item.def_id = str(row.get("def_id", ""))
	item.name = str(row.get("name", "词条"))
	item.tier = int(row.get("tier", 0))
	item.stat = str(row.get("stat", "dmg"))
	item.value = float(row.get("value", 0.0))
	item.desc = str(row.get("desc", ""))
	item.sell = int(row.get("sell", 40))
	return item


static func _roll_tier(state: GameState, cfg: ConfigDB) -> int:
	var weights := cfg.tier_weights(state.wave_index)
	var total := 0
	for w in weights:
		total += int(w)
	if total <= 0:
		return 0
	var roll := state.rng.randi_range(1, total)
	var acc := 0
	for i in range(weights.size()):
		acc += int(weights[i])
		if roll <= acc:
			return i
	return 0


static func _describe(item: GameState.Item) -> String:
	var pct := absf(item.value) * 100.0
	var label := ""
	match item.stat:
		"dmg": label = "伤害"
		"rate": label = "射击间隔"
		"spread": label = "散布"
		"repair": label = "修墙量"
		"speed": label = "移速"
		_: label = item.stat
	var sign_str := "+" if item.value >= 0.0 else "-"
	return "%s %s%.0f%%" % [label, sign_str, pct]


## 物品在背包里占几格（按稀有度：普通 1×1 / 精良 1×2 / 稀有 2×1 / 传说 2×2）
static func item_footprint(state: GameState, item: GameState.Item) -> Vector2i:
	var fp: Variant = state.bag_footprints.get(str(item.tier), Vector2i.ONE)
	if fp is Vector2i:
		return fp
	return Vector2i.ONE


static func bag_used_cells(state: GameState) -> int:
	var used := 0
	for it in state.items:
		var fp := footprint_of(state, it)
		used += fp.x * fp.y
	return used


## 背包排布（2026-11-10）：面积大的先放、同面积按 uid 升序做 first-fit。
## 放不下就整体失败并且**不改动** state.bag_layout —— 调用方据此拒绝拾取。
static func repack(state: GameState) -> bool:
	var cols: int = state.bag_cols
	var rows: int = state.bag_rows
	var total := cols * rows
	var occupied: Array = []
	for i in range(total):
		occupied.append(-1)
	var order: Array = []
	for i in range(state.items.size()):
		order.append(i)
	order.sort_custom(func(a, b):
		# 资源堆必须先放：否则装备塞满后 1x1 的资源进不来，
		# 会出现「背包满 -> 买不了弹药 -> 打不动墙」的死局（2026-11-15 实测踩到）。
		var ra := is_resource(state.items[a])
		var rb := is_resource(state.items[b])
		if ra != rb:
			return ra
		var fa := footprint_of(state, state.items[a])
		var fb := footprint_of(state, state.items[b])
		var aa := fa.x * fa.y
		var ab := fb.x * fb.y
		if aa != ab:
			return aa > ab
		return int(state.items[a].uid) < int(state.items[b].uid))
	var layout: Array = []
	for idx in order:
		var fp := footprint_of(state, state.items[idx])
		var spot := _first_fit(occupied, cols, rows, fp.x, fp.y)
		if spot.x < 0:
			return false
		for dy in range(fp.y):
			for dx in range(fp.x):
				occupied[(spot.y + dy) * cols + (spot.x + dx)] = idx
		layout.append({"uid": state.items[idx].uid, "x": spot.x, "y": spot.y,
			"w": fp.x, "h": fp.y})
	layout.sort_custom(func(a, b): return int(a["uid"]) < int(b["uid"]))
	state.bag_layout = layout
	return true


static func _first_fit(occupied: Array, cols: int, rows: int, w: int, h: int) -> Vector2i:
	for y in range(rows - h + 1):
		for x in range(cols - w + 1):
			var ok := true
			for dy in range(h):
				for dx in range(w):
					if int(occupied[(y + dy) * cols + (x + dx)]) != -1:
						ok = false
						break
				if not ok:
					break
			if ok:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


static func add_item(state: GameState, item: GameState.Item) -> bool:
	if item == null:
		return false
	state.items.append(item)
	if not repack(state):
		state.items.pop_back()
		repack(state)
		return false
	return true


static func equip(state: GameState, cfg: ConfigDB, uid: int) -> bool:
	var item := state.item_by_uid(uid)
	if item == null or state.equipped.has(uid):
		return false
	var used := 0
	for other_uid in state.equipped:
		var other := state.item_by_uid(int(other_uid))
		if other != null and other.kind == item.kind:
			used += 1
	if used >= int(state.slot_caps.get(item.kind, 0)):
		return false
	state.equipped.append(uid)
	recompute(state)
	return true


static func unequip(state: GameState, uid: int) -> bool:
	if not state.equipped.has(uid):
		return false
	state.equipped.erase(uid)
	recompute(state)
	return true


static func sell(state: GameState, uid: int) -> int:
	var item := state.item_by_uid(uid)
	if item == null:
		return 0
	# 资源堆不能卖：售价 0 且会整堆删除，等于把钱包清零（2026-11-15 踩到）
	if is_resource(item):
		return 0
	state.equipped.erase(uid)
	state.items.erase(item)
	grant(state, "coin", item.sell)   # 卖出所得进背包（资源唯一存储）
	recompute(state)
	return item.sell


## 包裹容量与表示（2026-11-15）：资源不再直接进计数器，而是变成**背包里的可叠加物品**。
## state.coin / brick / metal / ammo 改为由背包重算出来的聚合值（refresh_totals）。
## 这样商店、修墙、开火都能照旧读 state.coin，但唯一的真实存储是背包。
const RESOURCE_KINDS := ["coin", "brick", "metal", "ammo"]
const RESOURCE_LABELS := {"coin": "金币", "brick": "砖块", "metal": "金属", "ammo": "弹药"}
const RESOURCE_ICONS := {"coin": "icon_coin", "brick": "icon_brick",
	"metal": "icon_metal", "ammo": "icon_ammo"}
const BAG_COLS := 5
const BAG_ROWS := 2
const BAG_COLS_UPGRADED := 6
const BAG_ROWS_UPGRADED := 3


static func is_resource(item: GameState.Item) -> bool:
	return item != null and RESOURCE_KINDS.has(item.kind)


## 资源堆按 1×1 占位；装备按稀有度
static func footprint_of(state: GameState, item: GameState.Item) -> Vector2i:
	if is_resource(item):
		return Vector2i.ONE
	return item_footprint(state, item)


static func total_of(state: GameState, kind: String) -> int:
	var sum := 0
	for it in state.items:
		if it.kind == kind and is_resource(it):
			sum += int(it.count)
	return sum


## 把 state.coin/brick/metal/ammo 从背包重算一遍（唯一真实存储是背包）。
static func refresh_totals(state: GameState) -> void:
	state.coin = total_of(state, "coin")
	state.brick = total_of(state, "brick")
	state.metal = total_of(state, "metal")
	state.ammo = total_of(state, "ammo")


## 在背包里加资源：优先并入已有同类堆，没有就新开一个 1×1 堆。放不下返回 false。
static func grant(state: GameState, kind: String, amount: int) -> bool:
	if amount <= 0:
		return true
	for it in state.items:
		if it.kind == kind and is_resource(it):
			it.count += amount
			refresh_totals(state)
			return true
	var item := GameState.Item.new()
	state.item_seq += 1
	item.uid = state.item_seq
	item.kind = kind
	item.name = String(RESOURCE_LABELS.get(kind, kind))
	item.count = amount
	item.tier = 0
	item.stat = ""
	item.value = 0.0
	item.desc = ""
	item.sell = 0
	state.items.append(item)
	if not repack(state):
		state.items.pop_back()
		repack(state)
		return false
	refresh_totals(state)
	return true


## 从背包扣除资源（不足则整体失败、不做任何改动）。空堆会被移除。
static func spend(state: GameState, kind: String, amount: int) -> bool:
	if amount <= 0:
		return true
	if total_of(state, kind) < amount:
		return false
	var left := amount
	for it in state.items.duplicate():
		if left <= 0:
			break
		if not (it.kind == kind and is_resource(it)):
			continue
		var take := mini(int(it.count), left)
		it.count -= take
		left -= take
		if it.count <= 0:
			state.items.erase(it)
	repack(state)
	refresh_totals(state)
	return true


## 丢弃一件物品（资源整堆丢弃；装备整件丢弃）。用于背包满时腾格子。
static func drop_uid(state: GameState, uid: int) -> bool:
	var item := state.item_by_uid(uid)
	if item == null:
		return false
	state.equipped.erase(uid)
	state.items.erase(item)
	repack(state)
	refresh_totals(state)
	recompute(state)
	return true


## 背包扩容：只能变大；改动后重新排布，失败则回滚。
static func resize_bag(state: GameState, cols: int, rows: int) -> bool:
	if cols * rows <= state.bag_cols * state.bag_rows:
		return false
	var old_cols := state.bag_cols
	var old_rows := state.bag_rows
	state.bag_cols = cols
	state.bag_rows = rows
	state.bag_capacity = cols * rows
	if not repack(state):
		state.bag_cols = old_cols
		state.bag_rows = old_rows
		state.bag_capacity = old_cols * old_rows
		repack(state)
		return false
	return true


## 直接把某类资源设成指定数量。测试/读档用；正常玩法必须走 grant/spend。
static func set_total(state: GameState, kind: String, amount: int) -> void:
	for it in state.items.duplicate():
		if it.kind == kind and is_resource(it):
			state.items.erase(it)
	state.items = state.items          # 保持引用安全（erase 已生效）
	repack(state)
	refresh_totals(state)
	if amount > 0:
		grant(state, kind, amount)
	refresh_totals(state)


## 开局把 start_coin / start_ammo 等灌进背包（setup 末尾调用一次）。
static func seed_resources(state: GameState) -> void:
	var pending := {"coin": state.coin, "brick": state.brick,
		"metal": state.metal, "ammo": state.ammo}
	# 先清掉可能存在的资源堆，避免重复
	for it in state.items.duplicate():
		if is_resource(it):
			state.items.erase(it)
	state.coin = 0
	state.brick = 0
	state.metal = 0
	state.ammo = 0
	for kind in RESOURCE_KINDS:
		var amount := int(pending[kind])
		if amount > 0:
			grant(state, kind, amount)
	refresh_totals(state)
static func recompute(state: GameState) -> void:
	var stats := ["dmg", "rate", "spread", "repair", "speed"]
	var add := {}
	var mul := {}
	for s in stats:
		add[s] = 0.0
		mul[s] = 1.0
	for uid in state.equipped:
		var item := state.item_by_uid(int(uid))
		if item == null:
			continue
		if item.kind == "attachment":
			mul[item.stat] = float(mul[item.stat]) * (1.0 + item.value)
		else:
			add[item.stat] = float(add[item.stat]) + item.value
	var out := {}
	for s in stats:
		out[s] = (1.0 + float(add[s])) * float(mul[s])
	state.mods = out
