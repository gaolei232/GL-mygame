class_name RewardSystem
extends RefCounted
## 波末奖励：波次资源结算 + 选择项。
## 保留的核心玩法：第 1 波末强制“定向四选一”确定本局主题，后续奖励偏向该主题（R6）。

const THEMES := [
	{"id": "fire", "name": "火 · 灼烧", "desc": "主题：伤害溢出，换取持续灼烧"},
	{"id": "frost", "name": "霜 · 迟滞", "desc": "主题：减速控场，换取爆发不足"},
	{"id": "conduit", "name": "导能 · 连锁", "desc": "主题：多目标弹射，单体偏弱"},
	{"id": "guard", "name": "守卫 · 加固", "desc": "主题：墙体与守卫强化"},
]


static func prepare(state: GameState, cfg: ConfigDB) -> void:
	var row := cfg.wave_row(state.wave_index)
	for k in ["coin", "brick", "metal"]:
		InventorySystem.grant(state, k, int(row.get("reward_%s" % k, 0)))

	state.reward_choices.clear()
	if state.wave_index == 1:
		for t in THEMES:
			state.reward_choices.append({
				"id": t["id"], "name": t["name"], "desc": t["desc"], "kind": "theme"})
		return

	var pool := [
		{"id": "coin_pack", "name": "金币 ×200", "desc": "直接补充建设资金", "kind": "coin", "amount": 200},
		{"id": "brick_pack", "name": "砖块 ×30", "desc": "修墙与升级的刚需", "kind": "brick", "amount": 30},
		{"id": "metal_pack", "name": "金属 ×12", "desc": "武器与水晶升级用", "kind": "metal", "amount": 12},
		{"id": "ammo_pack", "name": "弹药 ×60", "desc": "下波火力储备", "kind": "ammo", "amount": 60},
		{"id": "weapon_up", "name": "弩 · 强化一级", "desc": "永久提升主武器", "kind": "weapon", "amount": 1},
		{"id": "wall_rebuild", "name": "全墙修复 40%", "desc": "立刻回填所有存活墙段", "kind": "repair", "amount": 0.4},
	]
	var picks: Array = []
	var themed := state.theme != ""
	while picks.size() < 3 and picks.size() < pool.size():
		var idx := state.rng.randi_range(0, pool.size() - 1)
		var item: Dictionary = pool[idx]
		if picks.has(item):
			continue
		if not themed and picks.size() == 2:
			item = pool[4]  # 保底：至少给一个成长项
		picks.append(item)
	for item in picks:
		state.reward_choices.append(item)


static func choose(state: GameState, cfg: ConfigDB, bus: EventBus, index: int) -> bool:
	if state.phase != GameState.Phase.REWARD:
		return false
	if index < 0 or index >= state.reward_choices.size():
		return false
	var pick: Dictionary = state.reward_choices[index]
	match str(pick["kind"]):
		"theme":
			state.theme = str(pick["id"])
		"coin": InventorySystem.grant(state, "coin", int(pick["amount"]))
		"brick": InventorySystem.grant(state, "brick", int(pick["amount"]))
		"metal": InventorySystem.grant(state, "metal", int(pick["amount"]))
		"ammo": InventorySystem.grant(state, "ammo", int(pick["amount"]))
		"weapon":
			var level := int(state.player.weapon_levels.get("crossbow", 1))
			state.player.weapon_levels["crossbow"] = mini(level + int(pick["amount"]), 6)
		"repair":
			var pct := float(pick["amount"])
			for seg in state.wall:
				if not seg.breached:
					seg.hp = minf(seg.max_hp, seg.hp + seg.max_hp * pct)
	bus.emit(EventBus.PURCHASE, {"key": "reward", "name": pick["name"]})
	state.reward_choices.clear()
	PhaseMachine.request(state, "next_round", cfg, bus)
	return true
