class_name ScoutSystem
extends RefCounted
## 搜集期：出城搜箱、被感染者追击、倒计时结束自动回城。
## 设计口径（保留的核心玩法）：搜集是「有成本的时间窗口」，不是无风险刷资源。
##
## 搜索式开箱（2026-11-09）：
## - 箱子生成时**预先抽定**内容与格位；之后只做「逐格扫描」，不再重抽。
##   内容由 (run_seed, 波次, 箱子序号) 决定 —— 读档/重进同一波拿到的是同一批箱子，
##   否则「离开保留未显现格」会变成反复进出重抽 5 级的漏洞。
## - 4×4 固定网格，指针从 0 扫到 15；每格耗时 = 该格等级时间或空格时间。
## - 离开盒子（走出半径）只是暂停，指针、已显现格、当前格剩余时间全部留在箱子字典里。
## - 扫完 16 格才算开完；物资在「扫到它的那一刻」就入账。

const CHASER_COUNT := 4          # 兼容旧参数；实际数量由 balance.loot.chaser_count 决定


static func begin(state: GameState, cfg: ConfigDB, bus: EventBus) -> void:
	state.loot_boxes.clear()
	state.enemies.clear()
	state.searching_box = -1
	state.near_box = -1
	# 2026-11-15：玩家能跑全图了，箱子改为**全图铺开**（数量↑、密度↓）。
	var count := int(cfg.num("loot", "box_count_scout", 18))
	var r_min := cfg.num("loot", "spawn_min", 24.0)
	var r_max := cfg.num("loot", "spawn_max", 146.0)
	for i in range(count):
		var pos := _spawn_point(state, cfg, r_min, r_max)
		var tier := "refined" if i % 3 == 2 else "common"
		var cells := _roll_content(state, cfg, i, tier)
		state.loot_boxes.append({
			"pos": pos,
			"opened": false,
			"tier": tier,
			"guard_ids": [],
			"cells": cells["cells"],
			"items": cells["items"],
			"revealed": cells["revealed"],
			"pointer": 0,
			"cell_left": 0.0,
			"cell_total": 0.0,
			"gain": {"coin": 0, "brick": 0, "metal": 0, "ammo": 0},
		})
	_station_guards(state, cfg)
	# 游荡追兵数量（2026-11-08）：默认 1 只，敌潮主力改为波次开始才落场
	var chasers := int(cfg.num("loot", "chaser_count", 1))
	for i in range(chasers):
		var pos := EnemyFactory.perimeter_point(state, cfg, i, maxi(1, chasers))
		EnemyFactory.spawn(state, cfg, "walker", pos, 1.0, 1.0)
	bus.emit(EventBus.NOTICE, {"text": "出城搜集 · 靠近箱子开始搜索（F 提前回城）"})


## 预抽定：件数 → 占位形状 → 位置 → 每件等级/类型/数量。全部用独立 rng，与逐帧随机流解耦。
## 占位按等级（1×1 / 1×2 / 2×1 / 2×2），放不下时逐级缩小；物品本身（等级/类型/产量）不变。
static func _roll_content(state: GameState, cfg: ConfigDB, box_index: int, box_tier: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = state.seed_value * 7919 + state.wave_index * 104729 + box_index * 1299709 + 17
	var cols := cfg.box_cols()
	var rows := cfg.box_rows()
	var total_cells := cols * rows
	var cells: Array = []
	for i in range(total_cells):
		cells.append(-1)                 # -1 = 空格；>=0 = items 下标
	var items: Array = []
	var n := clampi(int(_pick_weighted(rng, cfg.box_count_weights(box_tier))), 1, total_cells)
	var tier_weights: Array = cfg.box_tier_weights(state.wave_index, box_tier)
	var kinds: Dictionary = cfg.box_type_weights()
	for k in range(n):
		var tier := clampi(_pick_index(rng, tier_weights) + 1, 1, 5)
		var kind := _pick_key(rng, kinds)
		var amount := cfg.box_amount(kind, tier)
		var spot := _find_spot(rng, cells, cols, rows, cfg.box_footprint_steps(tier))
		if spot.is_empty():
			continue                    # 极端拥挤时宁可不生成，也不叠格
		var idx := items.size()
		var covered: Array = spot["cells"]
		for ci in covered:
			cells[int(ci)] = idx
		items.append({
			"kind": kind, "tier": tier, "amount": amount,
			"w": int(spot["w"]), "h": int(spot["h"]), "x": int(spot["x"]), "y": int(spot["y"]),
			"cells": covered, "revealed": false, "taken": false,
		})
	var revealed: Array = []
	for i in range(total_cells):
		revealed.append(false)
	return {"cells": cells, "items": items, "revealed": revealed}


## 在一张 4×4 的占用表里找位置：按降档形状依次尝试，返回首个可放的位置
static func _find_spot(rng: RandomNumberGenerator, cells: Array, cols: int, rows: int,
		shapes: Array) -> Dictionary:
	for shape in shapes:
		var w := int(shape.x)
		var h := int(shape.y)
		var cands: Array = []
		for y in range(rows - h + 1):
			for x in range(cols - w + 1):
				var ok := true
				for dy in range(h):
					for dx in range(w):
						if int(cells[(y + dy) * cols + (x + dx)]) != -1:
							ok = false
							break
					if not ok:
						break
				if ok:
					cands.append(Vector2i(x, y))
		if cands.is_empty():
			continue
		var pick: Vector2i = cands[rng.randi_range(0, cands.size() - 1)]
		var covered: Array = []
		for dy in range(h):
			for dx in range(w):
				covered.append((pick.y + dy) * cols + (pick.x + dx))
		return {"w": w, "h": h, "x": pick.x, "y": pick.y, "cells": covered}
	return {}


## 字典权重抽取：返回**原始键**（件数表是整数键、类型表是字符串键，不能一律转 int）
static func _pick_weighted(rng: RandomNumberGenerator, weights: Dictionary) -> Variant:
	var total := 0
	for k in weights:
		total += int(weights[k])
	if total <= 0:
		return null
	var roll := rng.randi_range(1, total)
	var acc := 0
	for k in weights:
		acc += int(weights[k])
		if roll <= acc:
			return k
	return null


## 数组权重：返回下标（等级权重表是 5 个一维数组）
static func _pick_index(rng: RandomNumberGenerator, weights: Array) -> int:
	var total := 0
	for w in weights:
		total += int(w)
	if total <= 0:
		return 0
	var roll := rng.randi_range(1, total)
	var acc := 0
	for i in range(weights.size()):
		acc += int(weights[i])
		if roll <= acc:
			return i
	return 0


static func _pick_key(rng: RandomNumberGenerator, weights: Dictionary) -> String:
	return str(_pick_weighted(rng, weights))



## 精良箱由 2–4 只敌人驻守：全部清空后才可开启
## 全图撒点：避开河道与地图边缘
static func _spawn_point(state: GameState, cfg: ConfigDB, r_min: float, r_max: float) -> Vector2:
	var half := cfg.num("world", "map_half", 160.0) - cfg.num("world", "map_margin", 10.0)
	var block := cfg.river_half_width + 6.0
	for _i in range(64):
		var r := state.rng.randf_range(r_min, r_max)
		var a := state.rng.randf_range(0.0, TAU)
		var p := Vector2(cos(a), sin(a)) * r
		if absf(p.x) > half or absf(p.y) > half:
			continue
		if _near_river(cfg, p, block):
			continue
		return p
	return Vector2(r_min, 0.0)


static func _near_river(cfg: ConfigDB, p: Vector2, block: float) -> bool:
	var pts: Array = cfg.river_points
	for i in range(pts.size() - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / maxf(0.0001, ab.length_squared()), 0.0, 1.0)
		if p.distance_to(a + ab * t) < block:
			return true
	return false


static func _station_guards(state: GameState, cfg: ConfigDB) -> void:
	var g_min := int(cfg.num("loot", "guard_min", 2))
	var g_max := int(cfg.num("loot", "guard_max", 4))
	var r_min := cfg.num("loot", "guard_radius_min", 3.0)
	var r_max := cfg.num("loot", "guard_radius_max", 6.0)
	var leash_r := cfg.num("loot", "guard_leash", 8.0)
	# 2026-11-15：箱子铺开后精良箱变多，若每箱都驻守，搜集期会挤满敌人。
	# 只给**前 2 个**精良箱派守卫，保持「低风险搜集」的基调。
	var guarded := 0
	for box in state.loot_boxes:
		if String(box["tier"]) != "refined":
			continue
		if guarded >= 2:
			break
		guarded += 1
		var box_pos: Vector2 = box["pos"]
		var count := state.rng.randi_range(g_min, g_max)
		for k in range(count):
			var angle := state.rng.randf_range(0.0, TAU)
			var r := state.rng.randf_range(r_min, r_max)
			var enemy := EnemyFactory.spawn(state, cfg, "walker", box_pos + Vector2(cos(angle), sin(angle)) * r)
			enemy.has_leash = true
			enemy.leash_pos = box_pos
			enemy.leash_r = leash_r
			box["guard_ids"].append(enemy.id)


static func step(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus) -> void:
	_move_chasers(state, dt, cfg)
	_search_boxes(state, dt, cfg, bus)


static func _move_chasers(state: GameState, dt: float, cfg: ConfigDB) -> void:
	var p := state.player.pos
	for e in state.enemies:
		if not e.alive:
			continue
		if e.has_leash and p.distance_to(e.leash_pos) > e.leash_r * 1.5:
			var back: Vector2 = e.leash_pos - e.pos
			if back.length() > 0.8:
				e.pos += back.normalized() * e.speed * 0.6 * dt
			continue
		var dir: Vector2 = p - e.pos
		if dir.length() > 1.2:
			e.pos += dir.normalized() * e.speed * dt
	_keep_enemies_in_bounds(state, cfg)


## 找半径内最近的箱子当作当前搜索目标；离开半径只是暂停（指针与剩余时间留在箱子里）
static func _search_boxes(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus) -> void:
	var radius := cfg.num("loot", "open_radius", 2.2)
	var near := -1
	var near_d := radius
	var scan := -1
	var scan_d := radius
	for i in range(state.loot_boxes.size()):
		var box: Dictionary = state.loot_boxes[i]
		var d: float = state.player.pos.distance_to(box["pos"])
		if d > radius:
			continue
		# near_box 包含「已搜完但还有物资没拾取」的箱子：
		# 否则箱子一搜完 searching_box 就归 -1，面板立刻关闭，
		# 玩家根本没机会双击拾取（2026-11-15 修）。
		if d <= near_d:
			near_d = d
			near = i
		if bool(box["opened"]):
			continue
		if d <= scan_d:
			scan_d = d
			scan = i
	state.near_box = near
	if scan < 0:
		state.searching_box = -1
		return
	if state.box_guarded_count(state.loot_boxes[scan]) > 0:
		state.searching_box = -1          # 有驻守：只能清完再搜
		return
	state.searching_box = scan
	_tick_search(state, dt, cfg, bus, scan)


static func _tick_search(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus, index: int) -> void:
	var box: Dictionary = state.loot_boxes[index]
	var cells: Array = box["cells"]
	var revealed: Array = box["revealed"]
	var pointer := int(box["pointer"])
	# 多格物品被扫到时会把占用的格一起标记；指针经过这些格不再耗时
	while pointer < cells.size() and bool(revealed[pointer]):
		pointer += 1
	box["pointer"] = pointer
	if pointer >= cells.size():
		_finish_box(state, cfg, bus, box)
		return
	if float(box["cell_left"]) <= 0.0:
		var t := cfg.box_empty_time()
		var idx := int(cells[pointer])
		if idx >= 0:
			var it: Dictionary = box["items"][idx]
			t = cfg.box_cell_time({"tier": int(it["tier"])})
		box["cell_total"] = t
		box["cell_left"] = t
	box["cell_left"] = float(box["cell_left"]) - dt
	if float(box["cell_left"]) > 0.0:
		return
	_reveal_cell(state, cfg, bus, box, pointer)
	box["pointer"] = pointer + 1
	box["cell_left"] = 0.0
	box["cell_total"] = 0.0
	if int(box["pointer"]) >= cells.size():
		_finish_box(state, cfg, bus, box)


## 扫到一格：命中的是多格物品就整件显现并标记它占的全部格；空格只标记自己
static func _reveal_cell(state: GameState, cfg: ConfigDB, bus: EventBus, box: Dictionary, index: int) -> void:
	var cells: Array = box["cells"]
	var revealed: Array = box["revealed"]
	var payload := {"index": index, "pos": box["pos"], "tier": box["tier"],
		"kind": "", "amount": 0, "item_tier": 0, "w": 0, "h": 0, "x": 0, "y": 0}
	var item_idx := int(cells[index])
	if item_idx >= 0:
		var item: Dictionary = box["items"][item_idx]
		if bool(item["revealed"]):
			return
		item["revealed"] = true
		for ci in item["cells"]:
			revealed[int(ci)] = true
		var kind := str(item["kind"])
		var amount := int(item["amount"])
		# 2026-11-15：扫描只负责**显现**，不再自动入账。
		# 物资留在箱子里，等玩家双击拾取（是否拿走由玩家决定）。
		payload["kind"] = kind
		payload["amount"] = amount
		payload["item_tier"] = int(item["tier"])
		payload["w"] = int(item["w"])
		payload["h"] = int(item["h"])
		payload["x"] = int(item["x"])
		payload["y"] = int(item["y"])
	else:
		revealed[index] = true
	bus.emit(EventBus.LOOT_REVEALED, payload)


static func _finish_box(state: GameState, cfg: ConfigDB, bus: EventBus, box: Dictionary) -> void:
	if bool(box["opened"]):
		return
	box["opened"] = true
	state.searching_box = -1
	# 精良箱额外产出的词条也不再自动入包：挂成待拾取，由玩家双击决定拿不拿
	if String(box["tier"]) == "refined":
		var item := InventorySystem.roll_item(state, cfg)
		if item != null:
			box["bonus"] = InventorySystem.item_to_dict(item)
	var gain: Dictionary = box["gain"]
	bus.emit(EventBus.LOOT_OPENED, {"pos": box["pos"], "tier": box["tier"],
		"gain": gain.duplicate(), "item": ""})


## 双击拾取（2026-11-15）：只在箱子**扫描完成**之后可用。
## item_index >= 0 取格子里的物资；-1 取精良箱附带的词条。
static func take(state: GameState, cfg: ConfigDB, bus: EventBus,
		box_index: int, item_index: int) -> bool:
	if box_index < 0 or box_index >= state.loot_boxes.size():
		return false
	var box: Dictionary = state.loot_boxes[box_index]
	if not bool(box["opened"]):
		bus.emit(EventBus.NOTICE, {"text": "先搜完这个箱子"})
		return false
	if item_index < 0:
		return _take_bonus(state, bus, box)
	var items: Array = box["items"]
	if item_index >= items.size():
		return false
	var item: Dictionary = items[item_index]
	if not bool(item.get("revealed", false)) or bool(item.get("taken", false)):
		return false
	var kind := str(item["kind"])
	var amount := int(item["amount"])
	if not InventorySystem.grant(state, kind, amount):
		bus.emit(EventBus.NOTICE, {"text": "背包已满 · 丢弃或卖出后再拿"})
		return false
	item["taken"] = true
	var gain: Dictionary = box["gain"]
	gain[kind] = int(gain.get(kind, 0)) + amount
	bus.emit(EventBus.ITEM_GAINED, {
		"name": String(InventorySystem.RESOURCE_LABELS.get(kind, kind)),
		"tier": int(item.get("tier", 1)), "desc": "+%d" % amount,
		"amount": amount, "resource": true})
	return true


static func _take_bonus(state: GameState, bus: EventBus, box: Dictionary) -> bool:
	var raw: Variant = box.get("bonus", null)
	if raw == null or typeof(raw) != TYPE_DICTIONARY or (raw as Dictionary).is_empty():
		return false
	var item := InventorySystem.item_from_dict(raw as Dictionary)
	if item == null:
		return false
	if not InventorySystem.add_item(state, item):
		bus.emit(EventBus.NOTICE, {"text": "背包已满 · 词条未拾取"})
		return false
	box["bonus"] = {}
	bus.emit(EventBus.ITEM_GAINED, {"name": item.name, "tier": item.tier, "desc": item.desc})
	return true


static func _keep_enemies_in_bounds(state: GameState, cfg: ConfigDB) -> void:
	# 追兵边界跟玩家一致（roam_radius + 少量余量），否则玩家能跑到 80m 而敌人停在 52m，
	# 搜集期就变成无风险刷资源。
	var half := cfg.num("world", "map_half", 160.0) - cfg.num("world", "map_margin", 5.0)
	for e in state.enemies:
		e.pos.x = clampf(e.pos.x, -half, half)
		e.pos.y = clampf(e.pos.y, -half, half)