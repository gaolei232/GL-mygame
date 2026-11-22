class_name GameState
extends RefCounted
## 状态容器：一局游戏的全部可读可写数据都在这里。
## 规则：只有 core/systems/* 可以写；view/ui 只读 snapshot()。
## 坐标约定：所有逻辑坐标都是 Vector2(x, z)，1 单位 = 1 米，与 3D 世界一致。

enum Phase { TITLE, SCOUT, BUILD, WAVE, REWARD, VICTORY, DEFEAT }


class PlayerState:
	var pos := Vector2.ZERO
	var aim := Vector2.ZERO
	var hp := 100.0
	var max_hp := 100.0
	var alive := true
	var death_count := 0
	var respawn_timer := 0.0
	var fire_cd := 0.0
	var melee_cd := 0.0
	var hurt_flash := 0.0
	var slots: Array = ["crossbow", ""]      # 槽 1 / 槽 2
	var owned_weapons: Array = ["crossbow"]  # 永久拥有，与两个快捷槽解耦
	var tools: Dictionary = {"hammer": "hammer", "knife": "knife"}
	var active_slot := 0                     # 0/1 = 枪槽，2 = 锤，3 = 刀
	var weapon_levels: Dictionary = {"crossbow": 1, "knife": 1}
	var moving := Vector2.ZERO
	# 翻滚（2026-11-08）：固定方向短冲刺 + 短暂无敌帧，参数在 balance.json.roll
	var rolling := false
	var roll_timer := 0.0
	var roll_cd := 0.0
	var roll_iframe := 0.0
	var roll_dir := Vector2.ZERO
	## 主动技能「瞬移」（Q）：向输入方向瞬移 blink_distance 米，冷却 blink_cd 秒
	var blink_cd := 0.0


class EnemyState:
	var id := 0
	var kind := "walker"
	var hp := 1.0
	var max_hp := 1.0
	var speed := 0.0
	var dmg := 0.0
	var interval := 1.0
	var atk_cd := 0.0
	var pos := Vector2.ZERO
	var alive := true
	var target_wall := -1
	var target_building := -1    # 建造物 id；-2 = 本波已判定「不追建造物」
	var phase := "walk"          # walk / attack / fuse / summon
	var fuse := -1.0
	var summon_done: Array = []
	var leash_pos := Vector2.ZERO    # 驻守点；ZERO 表示无拴绳
	var has_leash := false
	var leash_r := 8.0


class WallSegment:
	var index := 0
	var hp := 1000.0
	var max_hp := 1000.0
	var level := 1
	var center := Vector2.ZERO
	var tangent := Vector2.RIGHT
	var half_len := 4.0
	var breached := false
	var hit_flash := 0.0
	# 玩家新建的段才可拆除；初始 7 段是地形，不可拆
	var built := false
	var paid_coin := 0
	var paid_brick := 0
	var build_wave := 0


## 地面建造物（木箱 / 炮台）。城墙段仍走 WallSegment（战斗与存档都以它为准）。
class BuildingState:
	var id := 0
	var kind := "crate"          # crate / cannon
	var index := 1               # 计价序号（1-based）；木箱被毁后序号可复用
	var pos := Vector2.ZERO
	var hp := 1.0
	var max_hp := 1.0
	var stored: Array = []       # 木箱 25 格：{} / {kind, amount} / {kind:"item", item:{}}
	var stored_cols := 5
	var stored_rows := 5
	var paid_coin := 0
	var paid_brick := 0
	var paid_metal := 0
	var paid_ammo := 0
	var built_wave := 1
	var cooldown := 0.0          # 炮台射击冷却
	var hit_flash := 0.0


## 掉落物：资源堆 / 单件物品。木箱摧毁时按格生成，60s 后消失。
class DropState:
	var id := 0
	var pos := Vector2.ZERO
	var kind := "coin"           # coin / brick / metal / ammo / item
	var amount := 0
	var item: Dictionary = {}
	var ttl := 60.0


class Item:
	var uid := 0
	var kind := "trait"          # trait / attachment / coin / brick / metal / ammo
	var def_id := "sharp"
	var name := "词条"
	var tier := 0
	var stat := "dmg"
	var value := 0.08
	var desc := ""
	var sell := 40
	## 资源堆叠数量（2026-11-15）：kind 为 coin/brick/metal/ammo 时有效，其余为 0。
	## 资源按 1×1 占位，同类合并成一堆；state.coin 等是它重算出来的聚合值。
	var count := 0


class GuardState:
	var id := 0
	var hp := 480.0
	var max_hp := 480.0
	var armor := 4.0
	var dmg := 16.0
	var interval := 1.0
	var atk_cd := 0.0
	var pos := Vector2.ZERO
	var station := Vector2.ZERO
	var state := "idle"          # idle / intercept / attack / return
	var target_id := -1
	var alive := true


var phase: int = Phase.TITLE
var phase_time := 0.0
var phase_duration := 0.0

var wave_index := 1
var wave_elapsed := 0.0
var wave_spawned := 0
var wave_killed := 0
var wave_total := 0
var spawn_queue: Array = []          # [{kind, at, pos}]
var summon_pending: Array = []       # [{kind, delay}]

var coin := 0
var brick := 0
var metal := 0
var rare_mat := 0
var ammo := 0

var player: PlayerState = PlayerState.new()
var wall: Array = []                 # Array[WallSegment]
var enemies: Array = []              # Array[EnemyState]
var loot_boxes: Array = []           # [{pos, opened, tier, guard_ids, cells, revealed, pointer, ...}]
var searching_box := -1              # 正在搜索的箱子索引（-1 = 没有在搜）
var near_box := -1                   # 半径内最近的箱子（含被守卫的），供 UI 提示
var reward_choices: Array = []

# ---------------------------------------------------------------- 建造（2026-11-10）
var buildings: Array = []            # Array[BuildingState]：木箱 / 炮台
var drops: Array = []                # Array[DropState]：被摧毁/拆除后的掉落
var building_seq := 0
var drop_seq := 0
var crate_free_indices: Array = []   # 被摧毁木箱释放的计价序号（重建继承原价）
var crate_next_index := 1
var cannon_next_index := 1
var backpack_built := 0
var backpack_upgraded := false     ## 背包是否已换过 6×3 扩容包（商店只卖一次）
var base_bag_rows := 2               # items.json 的初始行数；扩容在这里累加
var wall_built_this_wave := 0        # 每波 1 段城墙的闸门
var near_crate := -1                 # 3m 内最近的木箱 building.id；-1 = 不在范围内

var items: Array = []                # Array[Item] 背包（P1-4）
var equipped: Array = []             # Array[int] 已装备物品 uid
var item_seq := 0
var bag_capacity := 10
var bag_cols := 5
var bag_rows := 2
var bag_footprints := {}          # tier -> Vector2i（普通 1×1 / 精良 1×2 / 稀有 2×1 / 传说 2×2）
var bag_layout: Array = []        # [{uid, x, y, w, h}]，由 InventorySystem.repack() 维护
var slot_caps := {"trait": 2, "attachment": 1}
var mods := {"dmg": 1.0, "rate": 1.0, "spread": 1.0, "repair": 1.0, "speed": 1.0}
var guards: Array = []               # Array[GuardState]
var guard_capacity := 1              # 本波满编人数（来自 crystal_levels.guard_count）

var crystal_hp := 560.0
var crystal_max_hp := 560.0
var crystal_level := 1
var crystal_hit_flash := 0.0
var roll_cooldown := 0.9            # 快照给 HUD 画冷却条用（参数源 balance.json.roll）

var theme := ""
var shop_refresh_used := false
var shop_stock: Array = []

var stats := {"shots": 0, "hits": 0, "kills": 0, "deaths": 0, "repair_hp": 0.0}
var seed_value := 0
var rng := RandomNumberGenerator.new()
var notice := ""
var notice_timer := 0.0


func setup(cfg: ConfigDB, run_seed: int = 0) -> void:
	seed_value = run_seed if run_seed != 0 else int(Time.get_unix_time_from_system())
	rng.seed = seed_value

	coin = int(cfg.num("player", "start_coin"))
	brick = int(cfg.num("player", "start_brick"))
	metal = int(cfg.num("player", "start_metal"))
	ammo = int(cfg.num("player", "start_ammo"))
	# 新局必须清空背包/装备/加成，否则上一局的词条会跨局残留
	items.clear()
	equipped.clear()
	bag_layout.clear()
	item_seq = 0
	mods = {"dmg": 1.0, "rate": 1.0, "spread": 1.0, "repair": 1.0, "speed": 1.0}
	bag_capacity = cfg.backpack_capacity()
	bag_cols = cfg.bag_cols()
	base_bag_rows = cfg.bag_rows()
	bag_rows = cfg.bag_rows()
	bag_footprints = cfg.bag_footprint_table()
	# 资源现在住在背包里（可叠加 1×1 堆）；这里把开局资源灌成背包物品，
	# 之后 coin/brick/metal/ammo 都是 InventorySystem.refresh_totals() 的聚合值。
	backpack_upgraded = false
	InventorySystem.seed_resources(self)
	# 新局必须清空建造物/掉落/计价序号：否则上一局的木箱、炮台、背包扩容会跨局残留
	buildings.clear()
	drops.clear()
	building_seq = 0
	drop_seq = 0
	crate_free_indices.clear()
	crate_next_index = 1
	cannon_next_index = 1
	backpack_built = 0
	wall_built_this_wave = 0
	near_crate = -1
	slot_caps = {"trait": cfg.slot_capacity("trait"), "attachment": cfg.slot_capacity("attachment")}
	player.max_hp = cfg.num("player", "max_hp", 100.0)
	player.hp = player.max_hp
	# 新局必须清掉「死亡/复活」残留：否则重开一局会以 alive=false 开场，
	# 要等上一局的复活倒计时走完才动得了（2026-11-09 由守卫用例暴露）
	player.alive = true
	player.respawn_timer = 0.0
	player.hurt_flash = 0.0
	player.fire_cd = 0.0
	player.melee_cd = 0.0
	# 新局必须清空武器养成与槽位配置，否则重开一局会继承上一局的强化等级（2026-11-09）
	player.weapon_levels = {"crossbow": 1, "light_crossbow": 1, "knife": 1, "hammer": 1}
	player.slots = ["crossbow", ""]
	player.owned_weapons = ["crossbow"]
	player.active_slot = 0
	player.death_count = 0
	# 新局必须清空翻滚状态，否则上一局的冷却/无敌帧会带进新局
	player.rolling = false
	player.roll_timer = 0.0
	player.roll_cd = 0.0
	player.roll_iframe = 0.0
	player.roll_dir = Vector2.ZERO
	player.blink_cd = 0.0
	roll_cooldown = cfg.num("roll", "cooldown", 0.9)

	crystal_max_hp = float(cfg.crystal_row(1).get("crystal_hp", 560))
	crystal_hp = crystal_max_hp
	crystal_level = 1

	_build_wall(cfg)
	player.pos = spawn_point(cfg)
	player.aim = player.pos + Vector2(0, -6)

	# 新局必须清空本局统计与主题（2026-11-09）：否则「重开」后击杀数继续累加、
	# 上一局选过的主题仍然生效——玩家从没选过，奖励池却已按主题加权。
	stats = {"shots": 0, "hits": 0, "kills": 0, "deaths": 0, "repair_hp": 0.0}
	theme = ""
	wave_killed = 0
	wave_total = 0
	reward_choices.clear()


## 玩家出生/回城/复活的唯一坐标来源（与 1 号守卫站位错开 2m）
static func spawn_point(cfg: ConfigDB) -> Vector2:
	return Vector2(2.0, -(float(cfg.num("world", "crystal_radius", 4.0)) + 1.5))


func _build_wall(cfg: ConfigDB) -> void:
	wall.clear()
	var count := int(cfg.num("world", "wall_segments", 7))
	var radius := cfg.num("world", "wall_radius", 22.0)
	var arc := deg_to_rad(cfg.num("world", "wall_arc_degrees", 150.0))
	var hp_total := cfg.num("world", "wall_hp_total", 11433.0)
	var seg_hp := hp_total / float(count)
	for i in range(count):
		var t := (float(i) + 0.5) / float(count) - 0.5
		var angle := t * arc
		var seg := WallSegment.new()
		seg.index = i
		seg.max_hp = seg_hp
		seg.hp = seg_hp
		seg.center = Vector2(sin(angle), -cos(angle)) * radius
		# 切线：沿弧线方向
		seg.tangent = Vector2(cos(angle), sin(angle)).normalized()
		seg.half_len = (arc * radius / float(count)) * 0.5 + 0.1
		wall.append(seg)


func alive_enemies() -> Array:
	var out: Array = []
	for e in enemies:
		if e.alive:
			out.append(e)
	return out


## 光标（地面点）指向的墙段索引（P0-7）：点到墙段线段的垂距 < tol 才算命中。
## 破口段不能升级，直接跳过；返回 -1 表示光标不在任何墙段上。
func wall_segment_at(pos: Vector2, tol: float = 2.5, include_breached: bool = false) -> int:
	var best := -1
	var best_d := tol
	for i in range(wall.size()):
		var seg: WallSegment = wall[i]
		if seg.breached and not include_breached:
			continue
		var a: Vector2 = seg.center - seg.tangent * seg.half_len
		var b: Vector2 = seg.center + seg.tangent * seg.half_len
		var d := _point_to_segment(pos, a, b)
		if d < best_d:
			best_d = d
			best = i
	return best


## 点到线段距离（core 不依赖物理/射线，纯解析几何，与 Combat 同风格）
static func _point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len2 := ab.length_squared()
	if len2 < 1e-6:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## 箱子仍有驻守敌人存活则返回其数量
func box_guarded_count(box: Dictionary) -> int:
	var n := 0
	for id in box.get("guard_ids", []):
		var e := enemy_by_id(int(id))
		if e != null and e.alive:
			n += 1
	return n


func guards_alive() -> Array:
	var out: Array = []
	for g in guards:
		if g.alive:
			out.append(g)
	return out


func building_by_id(id: int) -> BuildingState:
	for b in buildings:
		if b.id == id:
			return b
	return null


func crate_by_id(id: int) -> BuildingState:
	var b := building_by_id(id)
	return b if b != null and b.kind == "crate" else null


func _kind_count(kind: String) -> int:
	var n := 0
	for b in buildings:
		if b.kind == kind:
			n += 1
	return n


## 建造物占地半径：取 footprint 长边的一半。木箱 0.6m / 炮台 1.0m。
static func footprint_radius(def: Dictionary) -> float:
	var fp: Array = def.get("footprint", [1.0, 1.0])
	if fp.size() < 2:
		return 0.5
	return maxf(float(fp[0]), float(fp[1])) * 0.5


func guard_by_id(id: int) -> GuardState:
	for g in guards:
		if g.id == id:
			return g
	return null


func enemy_by_id(id: int) -> EnemyState:
	for e in enemies:
		if e.id == id:
			return e
	return null


func nearest_guard(pos: Vector2, max_dist: float = 1e9) -> GuardState:
	var best: GuardState = null
	var best_d := max_dist
	for g in guards:
		if not g.alive:
			continue
		var d: float = g.pos.distance_to(pos)
		if d < best_d:
			best_d = d
			best = g
	return best


func wall_breached_count() -> int:
	var n := 0
	for seg in wall:
		if seg.breached:
			n += 1
	return n


func all_walls_down() -> bool:
	return wall_breached_count() == wall.size()


func nearest_intact_wall(pos: Vector2, max_dist: float = 1e9) -> WallSegment:
	var best: WallSegment = null
	var best_d := max_dist
	for seg in wall:
		if seg.breached:
			continue
		var d := _dist_to_segment(pos, seg)
		if d < best_d:
			best_d = d
			best = seg
	return best


## 最近的需要修的墙段（满血的不算）：修墙按「有缺口可修」判定，避免对满血墙白扔砖
func nearest_damaged_wall(pos: Vector2, max_dist: float = 1e9) -> WallSegment:
	var best: WallSegment = null
	var best_d := max_dist
	for seg in wall:
		if seg.breached or seg.hp >= seg.max_hp - 0.5:
			continue
		var d := _dist_to_segment(pos, seg)
		if d < best_d:
			best_d = d
			best = seg
	return best


func dist_to_wall(pos: Vector2, seg: WallSegment) -> float:
	return _dist_to_segment(pos, seg)


func _dist_to_segment(p: Vector2, seg: WallSegment) -> float:
	var rel := p - seg.center
	var along: float = clampf(rel.dot(seg.tangent), -seg.half_len, seg.half_len)
	var closest := seg.center + seg.tangent * along
	return p.distance_to(closest)


## 只读快照：view/ui 的唯一数据来源，禁止外部持有引用
func snapshot() -> Dictionary:
	var walls: Array = []
	for seg in wall:
		walls.append({
			"index": seg.index, "hp": seg.hp, "max_hp": seg.max_hp,
			"level": seg.level, "breached": seg.breached,
			"center": seg.center, "tangent": seg.tangent,
			"half_len": seg.half_len, "hit_flash": seg.hit_flash,
			"built": seg.built, "paid_coin": seg.paid_coin, "paid_brick": seg.paid_brick,
		})
	var es: Array = []
	for e in enemies:
		if not e.alive:
			continue
		es.append({"id": e.id, "kind": e.kind, "pos": e.pos, "hp": e.hp,
			"max_hp": e.max_hp, "phase": e.phase, "fuse": e.fuse})
	var gs: Array = []
	for g in guards:
		gs.append({"id": g.id, "pos": g.pos, "hp": g.hp, "max_hp": g.max_hp,
			"state": g.state, "alive": g.alive})
	var boxes: Array = []
	for b in loot_boxes:
		boxes.append({
			"pos": b["pos"], "opened": b["opened"], "tier": b["tier"],
			"guarded": box_guarded_count(b),
			# 搜索式开箱：HUD 要画 4×4 网格、已显现格与当前格进度
			"cells": b.get("cells", []), "items": b.get("items", []),
			"revealed": b.get("revealed", []),
			"pointer": int(b.get("pointer", 0)),
			"cell_left": float(b.get("cell_left", 0.0)),
			"cell_total": float(b.get("cell_total", 0.0)),
			"gain": b.get("gain", {}),
			"bonus": b.get("bonus", {}),
		})
	var bs: Array = []
	for b in buildings:
		var used := 0
		for slot in b.stored:
			if not (slot as Dictionary).is_empty():
				used += 1
		bs.append({
			"id": b.id, "kind": b.kind, "index": b.index, "pos": b.pos,
			"hp": b.hp, "max_hp": b.max_hp, "hit_flash": b.hit_flash,
			"stored_used": used, "stored_total": b.stored.size(),
			"stored_cols": b.stored_cols, "stored_rows": b.stored_rows,
			"stored": b.stored.duplicate(true), "cooldown": b.cooldown,
			"built_wave": b.built_wave,
		})
	var ds: Array = []
	for d in drops:
		ds.append({
			"id": d.id, "pos": d.pos, "kind": d.kind, "amount": d.amount,
			"ttl": d.ttl, "item_name": str(d.item.get("name", "")) if d.kind == "item" else "",
		})
	var owned_weapons := player.owned_weapons.duplicate()
	for weapon_id in player.slots:
		var id := str(weapon_id)
		if id in ["crossbow", "light_crossbow", "longsword", "rifle", "pistol", "rpg"] \
				and not owned_weapons.has(id):
			owned_weapons.append(id)
	return {
		"phase": phase,
		"phase_name": phase_name(phase),
		"phase_time": phase_time,
		"phase_duration": phase_duration,
		"wave_index": wave_index,
		"wave_elapsed": wave_elapsed,
		"wave_alive": alive_enemies().size(),
		"wave_total": wave_total,
		"wave_killed": wave_killed,
		"coin": coin, "brick": brick, "metal": metal, "rare_mat": rare_mat, "ammo": ammo,
		"items": _items_view(),
		"equipped": equipped.duplicate(),
		"mods": mods.duplicate(),
		"bag_capacity": bag_capacity,
		"bag_cols": bag_cols, "bag_rows": bag_rows,
		"bag_layout": bag_layout.duplicate(true),
		"bag_used": InventorySystem.bag_used_cells(self),
		"slot_caps": slot_caps.duplicate(),
		"player": {
			"pos": player.pos, "aim": player.aim, "hp": player.hp, "max_hp": player.max_hp,
			"alive": player.alive, "respawn_timer": player.respawn_timer,
			"death_count": player.death_count, "active_slot": player.active_slot,
			"slots": player.slots.duplicate(), "owned_weapons": owned_weapons,
			"weapon_levels": player.weapon_levels.duplicate(),
			"hurt_flash": player.hurt_flash,
			"rolling": player.rolling, "roll_cd": player.roll_cd, "blink_cd": player.blink_cd,
			"roll_dir": player.roll_dir,
			"roll_cooldown": roll_cooldown,
		},
		"wall": walls,
		"crystal": {"hp": crystal_hp, "max_hp": crystal_max_hp,
			"level": crystal_level, "hit_flash": crystal_hit_flash},
		"enemies": es,
		"guards": gs,
		"guard_capacity": guard_capacity,
		"guards_alive": guards_alive().size(),
		"loot": boxes,
		"searching_box": searching_box,
		"near_box": near_box,
		"buildings": bs,
		"drops": ds,
		"near_crate": near_crate,
		"build_counts": {
			"crate": _kind_count("crate"),
			"backpack": backpack_built,
			"wall": wall_built_this_wave,
			"cannon": _kind_count("cannon"),
		},
		"crate_next_index": crate_next_index,
		"cannon_next_index": cannon_next_index,
		"crate_free_indices": crate_free_indices.duplicate(),
		"wall_built_this_wave": wall_built_this_wave,
		"backpack_built": backpack_built,
		"wall_segments": wall.size(),
		"reward_choices": reward_choices.duplicate(true),
		"theme": theme,
		"shop_stock": shop_stock.duplicate(true),
		"shop_refresh_used": shop_refresh_used,
		"stats": stats.duplicate(),
		"notice": notice,
		"notice_timer": notice_timer,
	}


func _items_view() -> Array:
	var out: Array = []
	for it in items:
		out.append({"uid": it.uid, "kind": it.kind, "def_id": it.def_id, "name": it.name,
			"tier": it.tier, "stat": it.stat, "value": it.value, "desc": it.desc,
			"sell": it.sell, "equipped": equipped.has(it.uid),
			"count": it.count, "is_resource": InventorySystem.is_resource(it)})
	return out


func item_by_uid(uid: int) -> Item:
	for it in items:
		if it.uid == uid:
			return it
	return null


static func phase_name(p: int) -> String:
	match p:
		Phase.TITLE: return "标题"
		Phase.SCOUT: return "搜集期"
		Phase.BUILD: return "建设期"
		Phase.WAVE: return "战斗期"
		Phase.REWARD: return "波末奖励"
		Phase.VICTORY: return "胜利"
		Phase.DEFEAT: return "失败"
	return "?"
