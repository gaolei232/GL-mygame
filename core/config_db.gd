class_name ConfigDB
extends RefCounted
## 配置层：唯一数值入口。
## 只读取 res://data 下的 TSV / JSON，不依赖任何 Node、场景或表现层对象。
## 设计约束：core 层任何系统只能通过 ConfigDB 拿数值，禁止硬编码。

const BALANCE_PATH := "res://data/balance.json"
const ITEMS_PATH := "res://data/items.json"
const LOOT_BOX_PATH := "res://data/loot_box.json"
const BUILDINGS_PATH := "res://data/buildings.json"
const TSV_DIR := "res://data/numeric/"

var balance: Dictionary = {}
var waves: Array = []            # 按 wave 升序
var enemies: Dictionary = {}     # kind -> row
var weapons: Dictionary = {}     # id -> {cls, levels:[{level,atk,interval,cost_coin,cost_metal}]}
var shop: Array = []             # 货架候选
var crystal_levels: Array = []   # 按 level 升序
var guards: Dictionary = {}      # kind -> {hp, armor, dmg, interval, aggro_r, reset_r}
var items_cfg: Dictionary = {}   # P1-4：稀有度 / 词条池 / 背包容量
## 河道折线（游戏坐标 x,z）与半宽：玩家可自由跑全图，但不能下水
var river_points: Array = []
var river_half_width := 9.0
var loot_box: Dictionary = {}    # 搜索式开箱：网格 / 扫描时长 / 数量与等级权重 / 单件产量
var buildings_cfg: Dictionary = {}  # 建造系统：四种建造物的价格/上限/占地/功能
var errors: PackedStringArray = []


func load_all() -> bool:
	errors.clear()
	balance = _read_json(BALANCE_PATH)
	var river := _read_json("res://data/river_path.json")
	if not river.is_empty():
		river_half_width = float(river.get("half_width", 9.0))
		for p in river.get("points", []):
			if p is Array and (p as Array).size() >= 2:
				river_points.append(Vector2(float(p[0]), float(p[1])))
	if balance.is_empty():
		return false
	waves = _read_tsv("waves.tsv", "wave")
	shop = _read_tsv("shop.tsv", "")
	crystal_levels = _read_tsv("crystal_levels.tsv", "level")
	_build_enemy_index(_read_tsv("enemies.tsv", "kind"))
	_build_guard_index(_read_tsv("guards.tsv", "kind"))
	items_cfg = _read_json(ITEMS_PATH)
	loot_box = _read_json(LOOT_BOX_PATH)
	buildings_cfg = _read_json(BUILDINGS_PATH)
	_build_weapon_index(_read_tsv("weapon_levels.tsv", ""))
	_validate()
	return errors.is_empty()


## 数值读取助手：缺 key 时返回默认值并记录一次错误，不静默吞掉
func num(section: String, key: String, fallback: float = 0.0) -> float:
	var sec: Dictionary = balance.get(section, {})
	if not sec.has(key):
		errors.append("balance.%s.%s 缺失" % [section, key])
		return fallback
	return float(sec[key])


func wave_row(wave_index: int) -> Dictionary:
	for row in waves:
		if int(row.get("wave", -1)) == wave_index:
			return row
	return {}


func enemy_row(kind: String) -> Dictionary:
	return enemies.get(kind, {})


func guard_row(kind: String = "default") -> Dictionary:
	return guards.get(kind, {})


# ---------------------------------------------------------------- P1-4 养成

func rarity_rows() -> Array:
	return items_cfg.get("rarity", [])


func rarity_row(tier: int) -> Dictionary:
	for row in rarity_rows():
		if int(row.get("tier", -1)) == tier:
			return row
	return {}


func item_defs() -> Array:
	return items_cfg.get("items", [])


func item_def(id: String) -> Dictionary:
	for row in item_defs():
		if String(row.get("id", "")) == id:
			return row
	return {}


func tier_weights(wave_index: int) -> Array:
	var table: Dictionary = items_cfg.get("tier_weights", {})
	var key := str(clampi(wave_index, 1, 5))
	return table.get(key, [100, 0, 0, 0])


func backpack_capacity() -> int:
	return bag_cols() * bag_rows()


## 背包网格（2026-11-10）：物品按稀有度占 1×1 / 1×2 / 2×1 / 2×2 格
func bag_cols() -> int:
	return int(items_cfg.get("bag_grid", {}).get("cols", 5))


func bag_rows() -> int:
	return int(items_cfg.get("bag_grid", {}).get("rows", 2))


## 稀有度 tier（0 普通 / 1 精良 / 2 稀有 / 3 传说）→ 占位
func bag_footprint(tier: int) -> Vector2i:
	var table: Dictionary = items_cfg.get("bag_footprints", {})
	var row: Array = table.get(str(clampi(tier, 0, 3)), [1, 1])
	if row.size() < 2:
		return Vector2i.ONE
	return Vector2i(int(row[0]), int(row[1]))


func bag_footprint_table() -> Dictionary:
	var out := {}
	for tier in range(4):
		out[str(tier)] = bag_footprint(tier)
	return out


func slot_capacity(kind: String) -> int:
	return int(items_cfg.get("slots", {}).get(kind, 0))


# ---------------------------------------------------------------- 建造（2026-11-10）

func building_defs() -> Array:
	return buildings_cfg.get("buildings", [])


func building_def(id: String) -> Dictionary:
	for row in building_defs():
		if String(row.get("id", "")) == id:
			return row
	return {}


func build_rule(key: String, fallback: float = 0.0) -> float:
	var rules: Dictionary = buildings_cfg.get("rules", {})
	if not rules.has(key):
		errors.append("buildings.rules.%s 缺失" % key)
		return fallback
	return float(rules[key])


func exchange_rate(kind: String, fallback: float = 0.0) -> float:
	var ex: Dictionary = buildings_cfg.get("exchange", {})
	return float(ex.get(kind, fallback))


## 基础金等价 = 表里的 coin + brick×6 + metal×20。growth 只乘这个等价，
## 砖/金属按表固定，coin 取差额——这样木箱砖块固定 15、炮台金属固定 9。
func building_base_equivalent(def: Dictionary) -> float:
	return float(def.get("cost_coin", 0)) \
		+ float(def.get("cost_brick", 0)) * exchange_rate("brick", 6.0) \
		+ float(def.get("cost_metal", 0)) * exchange_rate("metal", 20.0) \
		+ float(def.get("cost_ammo", 0)) * exchange_rate("ammo", 3.0)


## 第 n 个（1-based）的价格。迭代取整复现木箱表二：
## 240 → 312 → 406 → 528 → 686 → 892 → 1160 → 1508（不是 240×1.3^7=1506）。
func building_cost_at(id: String, index: int = 1) -> Dictionary:
	var def := building_def(id)
	if def.is_empty():
		return {}
	var n := maxi(1, index)
	var growth := float(def.get("growth", 1.0))
	var eq := building_base_equivalent(def)
	for i in range(1, n):
		eq = round(eq * growth)
	var brick := int(def.get("cost_brick", 0))
	var metal := int(def.get("cost_metal", 0))
	var ammo := int(def.get("cost_ammo", 0))
	var coin := int(round(eq
		- float(brick) * exchange_rate("brick", 6.0)
		- float(metal) * exchange_rate("metal", 20.0)
		- float(ammo) * exchange_rate("ammo", 3.0)))
	if id == "wall":
		# 城墙段的金币价继续走「每波最大金币均值 × 50%」的公式（当前 = 305），
		# 表里的 305 是公式快照；改 waves.tsv 时造价值跟着动。
		coin = wall_build_coin_cost()
	coin = maxi(0, coin)
	return {
		"coin": coin, "brick": brick, "metal": metal, "ammo": ammo,
		"equivalent": int(round(coin
			+ float(brick) * exchange_rate("brick", 6.0)
			+ float(metal) * exchange_rate("metal", 20.0)
			+ float(ammo) * exchange_rate("ammo", 3.0))),
		"index": n,
	}


func wall_segment_hp() -> float:
	return num("world", "wall_hp_total", 85000.0) / maxf(1.0, num("world", "wall_segments", 7))


func weapon_level_row(weapon_id: String, level: int) -> Dictionary:
	var w: Dictionary = weapons.get(weapon_id, {})
	var levels: Array = w.get("levels", [])
	var best: Dictionary = {}
	for row in levels:
		if int(row["level"]) <= level:
			best = row
	return best


func weapon_class(weapon_id: String) -> String:
	return str(weapons.get(weapon_id, {}).get("cls", "ranged"))


## 建造一段新墙的金币价（2026-11-09 规则）：每波「理论最大金币收益」的平均值 × 50%。
## 最大收益 = 波次奖励 + 全部敌人掉落 + 一次搜集期（4 普通箱 + 2 精良箱 + 1 追兵）。
## 之所以用「最大」而不是「期望」：段数无上限，必须用收益上界做闸门，否则越造越赚。
func wall_build_coin_cost() -> int:
	if waves.is_empty():
		return 0
	var total := 0.0
	for row in waves:
		total += wave_max_coin(row)
	return int(round(total / float(waves.size()) * 0.5))


func wave_max_coin(row: Dictionary) -> float:
	var coin := float(row.get("reward_coin", 0))
	for kind in ["walker", "runner", "brute", "bomber"]:
		coin += float(int(row.get(kind, 0))) * float(enemy_row(kind).get("drop_coin", 0))
	var walker_drop := float(enemy_row("walker").get("drop_coin", 0))
	coin += float(int(row.get("summon_walker", 0))) * walker_drop
	return coin + scout_coin_income(int(row.get("wave", 1)))


## 箱子的件数期望（普通 2.70 / 精良 4.25）
func expected_box_count(box_tier: String) -> float:
	var cw: Dictionary = box_count_weights(box_tier)
	var total := 0.0
	var sum := 0.0
	for k in cw:
		total += float(cw[k])
		sum += float(int(k)) * float(cw[k])
	return sum / maxf(1.0, total)


## 一次搜集期的金币收入（按新开箱模型的**期望**，不是理论最大）。
## 4×4 网格下理论最大（6 箱全 5 件全 5 级金币）约 1770，用它定墙价会让城墙涨价 6 倍；
## 这里用期望值作为「可获得的收入上界」，口径见文档 §R9.4。
func scout_coin_income(wave_index: int) -> float:
	var loot: Dictionary = balance.get("loot", {})
	var boxes := int(loot.get("box_count_scout", 6))
	var refined := boxes / 3
	var common := boxes - refined
	var share := float(box_type_weights().get("coin", 40)) / 100.0
	var income := float(common) * expected_box_count("common") * share * _coin_ev(wave_index, "common")
	income += float(refined) * expected_box_count("refined") * share * _coin_ev(wave_index, "refined")
	income += float(int(loot.get("chaser_count", 1))) * float(enemy_row("walker").get("drop_coin", 0))
	return income


## 单件金币的等级期望：Σ 权重占比 × 该级产量
func _coin_ev(wave_index: int, box_tier: String) -> float:
	var weights: Array = box_tier_weights(wave_index, box_tier)
	var total := 0.0
	for w in weights:
		total += float(w)
	if total <= 0.0:
		return 0.0
	var ev := 0.0
	for i in range(weights.size()):
		ev += float(weights[i]) / total * float(box_amount("coin", i + 1))
	return ev


func crystal_row(level: int) -> Dictionary:
	var best: Dictionary = {}
	for row in crystal_levels:
		if int(row["level"]) <= level:
			best = row
	return best


# ---------------------------------------------------------------- 搜索式开箱（2026-11-09）

func box_cols() -> int:
	return int(loot_box.get("grid", {}).get("cols", 4))


func box_rows() -> int:
	return int(loot_box.get("grid", {}).get("rows", 4))


func box_cell_count() -> int:
	return box_cols() * box_rows()


func box_empty_time() -> float:
	return float(loot_box.get("search", {}).get("empty_time", 0.18))


## 抖动只作用于表现层，不参与结算
func box_time_jitter() -> float:
	return float(loot_box.get("search", {}).get("jitter", 0.05))


## 扫过这一格的耗时：空格 0.18s，物资按等级 0.20–0.45s
func box_cell_time(cell: Dictionary) -> float:
	if cell.is_empty():
		return box_empty_time()
	var tier := clampi(int(cell.get("tier", 1)), 1, 5)
	var times: Array = loot_box.get("cell_time", [0.20, 0.30, 0.35, 0.40, 0.45])
	return float(times[tier - 1])


func box_count_weights(box_tier: String) -> Dictionary:
	return loot_box.get("boxes", {}).get(box_tier, {}).get("count_weights", {})


## 等级权重按波次查；精良箱用 波次+2（W1 用 W3 行），越界夹到首尾行
func box_tier_weights(wave_index: int, box_tier: String) -> Array:
	var offset := int(loot_box.get("boxes", {}).get(box_tier, {}).get("wave_offset", 0))
	var table: Dictionary = loot_box.get("tier_weights", {})
	var keys: Array = []
	for k in table.keys():
		keys.append(int(k))
	if keys.is_empty():
		return [100, 0, 0, 0, 0]
	keys.sort()
	var w := clampi(wave_index + offset, int(keys[0]), int(keys[keys.size() - 1]))
	var row: Array = table.get(str(w), table.get(str(keys[0]), [100, 0, 0, 0, 0]))
	return row


func box_type_weights() -> Dictionary:
	return loot_box.get("type_weights", {"coin": 40, "brick": 30, "ammo": 20, "metal": 10})


## 单件产量：kind ∈ coin/brick/ammo/metal，tier 1..5
func box_amount(kind: String, tier: int) -> int:
	var arr: Array = loot_box.get("amounts", {}).get(kind, [])
	if arr.is_empty():
		return 0
	return int(arr[clampi(tier, 1, arr.size()) - 1])


## 该等级物品在箱子网格里占几格（2×2 / 1×2 / 2×1 / 1×1）
func box_footprint(tier: int) -> Vector2i:
	var table: Dictionary = loot_box.get("footprints", {})
	var row: Array = table.get(str(clampi(tier, 1, 5)), [1, 1])
	if row.size() < 2:
		return Vector2i.ONE
	return Vector2i(int(row[0]), int(row[1]))


## 放不下时的降档顺序：2×2 → 1×2 → 1×1（只缩占位，不改物品等级/产量）
func box_footprint_steps(tier: int) -> Array:
	var fp := box_footprint(tier)
	var out: Array = [fp]
	if fp == Vector2i(2, 2):
		out.append(Vector2i(2, 1))
		out.append(Vector2i(1, 2))
	if fp != Vector2i.ONE:
		out.append(Vector2i.ONE)
	return out


# ---------------------------------------------------------------- 内部实现

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		errors.append("缺少配置文件：%s" % path)
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("JSON 解析失败：%s" % path)
		return {}
	return parsed


func _read_tsv(filename: String, key_field: String) -> Array:
	var path := TSV_DIR + filename
	var out: Array = []
	if not FileAccess.file_exists(path):
		errors.append("缺少配表：%s" % path)
		return out
	var text := FileAccess.get_file_as_string(path).replace("\ufeff", "")
	var lines := text.split("\n", false)
	if lines.size() < 2:
		errors.append("配表为空：%s" % path)
		return out
	var header := lines[0].strip_edges().split("\t")
	for i in range(1, lines.size()):
		var line := lines[i].strip_edges()
		if line.is_empty():
			continue
		var cells := line.split("\t")
		if cells.size() != header.size():
			errors.append("%s 第 %d 行列数不匹配" % [filename, i + 1])
			continue
		var row := {}
		for c in range(header.size()):
			row[header[c]] = _coerce(cells[c])
		if key_field != "":
			row["_key"] = row.get(key_field, "")
		out.append(row)
	if key_field != "":
		out.sort_custom(func(a, b): return str(a["_key"]) < str(b["_key"]))
	return out


func _coerce(raw: String) -> Variant:
	var s := raw.strip_edges()
	if s.is_valid_int():
		return int(s)
	if s.is_valid_float():
		return float(s)
	return s


func _build_enemy_index(rows: Array) -> void:
	for row in rows:
		enemies[str(row["kind"])] = row


func _build_guard_index(rows: Array) -> void:
	for row in rows:
		guards[String(row["kind"])] = row


func _build_weapon_index(rows: Array) -> void:
	for row in rows:
		var id := str(row["weapon_id"])
		if not weapons.has(id):
			weapons[id] = {"cls": str(row.get("cls", "ranged")), "levels": []}
		weapons[id]["levels"].append(row)
	for id in weapons:
		weapons[id]["levels"].sort_custom(func(a, b): return int(a["level"]) < int(b["level"]))


func _validate_items() -> void:
	if items_cfg.is_empty():
		errors.append("items.json 缺失或解析失败")
		return
	if rarity_rows().size() != 4:
		errors.append("items.json 稀有度必须 4 档，实际 %d" % rarity_rows().size())
	var allowed: Array = items_cfg.get("stats", [])
	var last_mult := 0.0
	for row in rarity_rows():
		var mult := float(row.get("mult", 0.0))
		if mult < last_mult:
			errors.append("稀有度倍率必须单调递增：tier %d" % int(row.get("tier", -1)))
		last_mult = mult
	if bag_cols() <= 0 or bag_rows() <= 0:
		errors.append("items.json bag_grid 非法：%dx%d" % [bag_cols(), bag_rows()])
	var bag_fp: Dictionary = items_cfg.get("bag_footprints", {})
	for t in range(4):
		var fp_row: Array = bag_fp.get(str(t), [])
		if fp_row.size() < 2 or int(fp_row[0]) < 1 or int(fp_row[1]) < 1:
			errors.append("items.json bag_footprints[%d] 非法" % t)
	if item_defs().is_empty():
		errors.append("items.json 词条池为空")
	for row in item_defs():
		var kind := String(row.get("kind", ""))
		if kind != "trait" and kind != "attachment":
			errors.append("词条 %s 的 kind 非法：%s" % [row.get("id", "?"), kind])
		if not (String(row.get("stat", "")) in allowed):
			errors.append("词条 %s 的 stat 不在白名单：%s" % [row.get("id", "?"), row.get("stat", "")])


func _validate_loot_box() -> void:
	if loot_box.is_empty():
		errors.append("loot_box.json 缺失或解析失败")
		return
	if box_cell_count() != 16:
		errors.append("loot_box 网格必须是 4×4=16 格，实际 %d" % box_cell_count())
	var times: Array = loot_box.get("cell_time", [])
	if times.size() != 5:
		errors.append("loot_box.cell_time 必须 5 档，实际 %d" % times.size())
	var amounts: Dictionary = loot_box.get("amounts", {})
	for kind in ["coin", "brick", "ammo", "metal"]:
		var arr: Array = amounts.get(kind, [])
		if arr.size() != 5:
			errors.append("loot_box.amounts.%s 必须 5 档，实际 %d" % [kind, arr.size()])
	var tw: Dictionary = loot_box.get("type_weights", {})
	if tw.is_empty():
		errors.append("loot_box.type_weights 为空")
	for key in ["common", "refined"]:
		var cw: Dictionary = loot_box.get("boxes", {}).get(key, {}).get("count_weights", {})
		if cw.is_empty():
			errors.append("loot_box.boxes.%s.count_weights 为空" % key)
	var rows: Dictionary = loot_box.get("tier_weights", {})
	if rows.is_empty():
		errors.append("loot_box.tier_weights 为空")
	for k in rows.keys():
		var row: Array = rows[k]
		if row.size() != 5:
			errors.append("loot_box.tier_weights[%s] 必须 5 档，实际 %d" % [str(k), row.size()])


func _validate_buildings() -> void:
	if buildings_cfg.is_empty():
		errors.append("buildings.json 缺失或解析失败")
		return
	if exchange_rate("brick", 0.0) <= 0.0 or exchange_rate("metal", 0.0) <= 0.0:
		errors.append("buildings.json exchange.brick/metal 必须 > 0")
	var defs := building_defs()
	if defs.size() != 4:
		errors.append("buildings.json 必须 4 种建造物，实际 %d" % defs.size())
	var ids := {}
	for def in defs:
		var id := String(def.get("id", ""))
		if id == "" or ids.has(id):
			errors.append("buildings.json 建造物 id 为空或重复：%s" % id)
			continue
		ids[id] = true
		for key in ["cost_coin", "cost_brick", "cost_metal", "cost_ammo"]:
			if float(def.get(key, -1)) < 0.0:
				errors.append("建筑 %s 的 %s 不能为负" % [id, key])
		if float(def.get("growth", 0.0)) < 1.0:
			errors.append("建筑 %s 的 growth 必须 >= 1.0" % id)
		if int(def.get("max_count", -1)) < 0:
			errors.append("建筑 %s 的 max_count 必须 >= 0（0 = 不限）" % id)
		if int(def.get("max_per_wave", 0)) < 0:
			errors.append("建筑 %s 的 max_per_wave 不能为负" % id)
		var placement := String(def.get("placement", ""))
		if not (placement in ["city", "self", "ring"]):
			errors.append("建筑 %s 的 placement 非法：%s" % [id, placement])
		var fp: Array = def.get("footprint", [])
		if fp.size() != 2 or float(fp[0]) < 0.0 or float(fp[1]) < 0.0:
			errors.append("建筑 %s 的 footprint 非法" % id)
	for required in ["crate", "backpack", "wall", "cannon"]:
		if not ids.has(required):
			errors.append("buildings.json 缺少 %s" % required)
	var crate := building_def("crate")
	var storage: Dictionary = crate.get("storage", {})
	if int(storage.get("slots", 0)) != 25 \
			or int(storage.get("cols", 0)) * int(storage.get("rows", 0)) != 25:
		errors.append("木箱 storage 必须是 5×5=25 格")
	if absf(float(storage.get("access_radius", 0.0)) - 3.0) > 0.01:
		errors.append("木箱存取半径必须是 3.0m")
	var backpack := building_def("backpack")
	if int(backpack.get("add_slots", 0)) != bag_cols() * int(backpack.get("add_rows", 0)):
		errors.append("背包 add_slots 必须等于 bag_cols × add_rows")
	var wall := building_def("wall")
	if int(wall.get("max_per_wave", 0)) != 1:
		errors.append("城墙段必须是每波 1 段")
	if absf(float(wall.get("hp", 0.0)) - wall_segment_hp()) > 1.0:
		errors.append("城墙段 hp 必须等于 wall_hp_total / wall_segments（12143）")
	var cannon := building_def("cannon")
	var attack: Dictionary = cannon.get("attack", {})
	if float(attack.get("dps", 0.0)) <= 0.0:
		errors.append("炮台 attack.dps 必须 > 0")
	if float(attack.get("range", 0.0)) <= 0.0:
		errors.append("炮台 attack.range 必须 > 0")


func _validate() -> void:
	if waves.size() != 5:
		errors.append("waves.tsv 期望 5 波，实际 %d" % waves.size())
	if crystal_levels.size() != 10:
		errors.append("crystal_levels.tsv 期望 10 级，实际 %d" % crystal_levels.size())
	if enemies.is_empty():
		errors.append("enemies.tsv 无有效数据")
	if guards.is_empty():
		errors.append("guards.tsv 无有效数据")
	_validate_items()
	_validate_loot_box()
	_validate_buildings()
	if weapons.is_empty():
		errors.append("weapon_levels.tsv 无有效数据")
