extends RefCounted
## 测试用自动驾驶：把「人怎么玩」写成可复现的策略，供冒烟与数值校准共用。
## 它不是游戏逻辑，只在 tests 里使用；策略改这里，所有跑批结果同步变化。

## 离最近敌人超过这个距离才允许切锤子修墙（贴脸时先打架）
const REPAIR_SAFE_DIST := 12.0

static func cmd(sim: Sim) -> Dictionary:
	var s := sim.state
	var out := {"move": Vector2.ZERO, "aim": s.player.pos + Vector2(0, -1),
		"fire": false, "action": false, "switch_to": -1}
	match s.phase:
		GameState.Phase.SCOUT:
			_scout(sim, s, out)
		GameState.Phase.BUILD:
			_build(sim, out)
		GameState.Phase.WAVE:
			_wave(s, out)
		GameState.Phase.REWARD:
			RewardSystem.choose(s, sim.cfg, sim.bus, 0)
	return out


static func _scout(sim: Sim, s: GameState, out: Dictionary) -> void:
	var target := Vector2.ZERO
	var best := 1e9
	for box in s.loot_boxes:
		if box["opened"] or s.box_guarded_count(box) > 0:
			continue
		var d: float = s.player.pos.distance_to(box["pos"])
		if d < best:
			best = d
			target = box["pos"]
	if s.searching_box >= 0:
		# 搜索是持续行为：停在箱子边（1.2m）等它扫完，别把指针晃出去
		var box_pos: Vector2 = s.loot_boxes[s.searching_box]["pos"]
		var d := s.player.pos.distance_to(box_pos)
		out["move"] = (box_pos - s.player.pos).normalized() if d > 1.2 else Vector2.ZERO
	elif best < 1e9:
		out["move"] = (target - s.player.pos).normalized()
	# 2026-11-15：箱子改成「扫描完 + 双击才入包」，机器人对应策略是自动全拾，
	# 否则搜集期拿不到任何资源，整条经济链与平衡测试都会失效。
	for bi in range(s.loot_boxes.size()):
		var box: Dictionary = s.loot_boxes[bi]
		if not bool(box.get("opened", false)):
			continue
		var items: Array = box.get("items", [])
		for ii in range(items.size()):
			var it: Dictionary = items[ii]
			if bool(it.get("revealed", false)) and not bool(it.get("taken", false)):
				sim.take_loot(bi, ii)
		var bonus: Variant = box.get("bonus", {})
		if bonus is Dictionary and not (bonus as Dictionary).is_empty():
			sim.take_loot(bi, -1)
	if s.phase_time > s.phase_duration - 4.0:
		sim.request("return_city")


static func _build(sim: Sim, out: Dictionary) -> void:
	var s := sim.state
	if s.brick < 10:
		for i in range(s.shop_stock.size()):
			if String(s.shop_stock[i]["key"]) == "brick_pack":
				EconomySystem.buy(s, sim.cfg, sim.bus, i)
				break
	var guard := 0
	while s.ammo < 150 and guard < 4:
		guard += 1
		var bought := false
		for i in range(s.shop_stock.size()):
			if String(s.shop_stock[i]["key"]) == "ammo_pack":
				bought = EconomySystem.buy(s, sim.cfg, sim.bus, i)
				break
		if not bought:
			break
	# 有余钱就买词条（覆盖"带装备 build"的强度）
	if s.coin > 400 and s.metal >= 3:
		for i in range(s.shop_stock.size()):
			if String(s.shop_stock[i]["key"]) == "trait_common":
				EconomySystem.buy(s, sim.cfg, sim.bus, i)
				break
	# 能装就装：词条/配件优先占满装备位；装不下的卖掉换钱
	for it in s.items:
		if not s.equipped.has(it.uid):
			InventorySystem.equip(s, sim.cfg, it.uid)
	for it in s.items.duplicate():
		# 资源堆是钱包（金币/砖/金属/弹药），不能当垃圾卖掉 —— 卖了等于清零
		if InventorySystem.is_resource(it):
			continue
		if not s.equipped.has(it.uid) and s.items.size() >= s.bag_capacity - 1:
			InventorySystem.sell(s, it.uid)
	EconomySystem.upgrade_crystal(s, sim.cfg, sim.bus)
	PhaseMachine.request(s, "start_wave", sim.cfg, sim.bus)


static func _wave(s: GameState, out: Dictionary) -> void:
	var focus := worst_wall(s)
	var stand := Vector2.ZERO
	if focus != null:
		stand = focus.center + (-focus.center.normalized()) * 2.2
	var enemy: GameState.EnemyState = null
	var bd := 1e9
	for e in s.enemies:
		if not e.alive:
			continue
		var d: float = s.player.pos.distance_to(e.pos)
		if d < bd:
			bd = d
			enemy = e
	# 修墙的前提是「没被贴脸」（2026-11-09）：原来只看墙血 < 70%，
	# 18 只敌人围着打时墙血在阈值下反复、bot 一直举锤子不还手，
	# 实测 seed 1003 第 4 波击杀停在 10/28 达 260s。贴身时必须先打，杀了才降 DPS。
	var repairing := s.brick > 0 and focus != null \
		and float(focus.hp) / maxf(1.0, float(focus.max_hp)) < 0.7 and bd > REPAIR_SAFE_DIST
	if repairing:
		out["switch_to"] = 2
		out["fire"] = true
		out["move"] = (stand - s.player.pos) * 0.6
	elif enemy != null:
		out["switch_to"] = 0
		out["aim"] = enemy.pos
		out["fire"] = bd < 26.0
		if bd < 7.0:
			var away: Vector2 = (s.player.pos - enemy.pos).normalized()
			var side := Vector2(-away.y, away.x)
			out["move"] = away * 0.9 + side * 0.5
		elif stand != Vector2.ZERO and s.player.pos.distance_to(stand) > 3.0:
			out["move"] = (stand - s.player.pos).normalized()


static func worst_wall(s: GameState) -> GameState.WallSegment:
	var worst: GameState.WallSegment = null
	var ratio := 2.0
	for seg in s.wall:
		if seg.breached:
			continue
		var r: float = seg.hp / maxf(1.0, seg.max_hp)
		if r < ratio:
			ratio = r
			worst = seg
	return worst
