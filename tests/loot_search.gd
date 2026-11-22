extends SceneTree
## 搜索式开箱（2026-11-09）口径验收：4×4 网格 / 预抽定 / 逐格扫描 / 离开保留 / 产量与权重。

const DT := 1.0 / 60.0

var cfg: ConfigDB
var checks := 0
var failures := 0


func _init() -> void:
	cfg = ConfigDB.new()
	if not cfg.load_all():
		printerr("配置加载失败：", cfg.errors)
		quit(1)
		return
	_test_grid_and_content()
	_test_determinism()
	_test_scan_timing()
	_test_leave_and_resume()
	_test_guarded_box()
	_test_tables()
	print("CHECKS %d, FAILURES %d" % [checks, failures])
	print("LOOT_SEARCH %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 2)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _start(seed_value: int) -> Sim:
	var sim := Sim.new(cfg)
	sim.new_run(seed_value)
	sim.request("start_run")
	sim.drain_events()
	return sim


func _items(box: Dictionary) -> int:
	return (box["items"] as Array).size() if box.has("items") else 0


## 箱内占位是否自洽：每件占 w×h 格、格互不重叠、都在 4×4 内
func _layout_ok(box: Dictionary) -> bool:
	var items: Array = box["items"]
	var cells: Array = box["cells"]
	if cells.size() != 16:
		return false
	var seen := {}
	for it in items:
		var w := int(it["w"])
		var h := int(it["h"])
		var x := int(it["x"])
		var y := int(it["y"])
		if (it["cells"] as Array).size() != w * h:
			return false
		if x < 0 or y < 0 or x + w > 4 or y + h > 4:
			return false
		for ci in it["cells"]:
			var c := int(ci)
			if c < 0 or c >= 16 or seen.has(c):
				return false
			seen[c] = true
			if int(cells[c]) != items.find(it):
				return false
	for i in range(16):
		if not seen.has(i) and int(cells[i]) != -1:
			return false
	return true


func _stand(sim: Sim, box: Dictionary) -> void:
	sim.state.player.pos = box["pos"]


func _step(sim: Sim, seconds: float) -> Array:
	var ev: Array = []
	var steps := int(seconds / DT)
	for i in range(steps):
		sim.step(DT, {"move": Vector2.ZERO, "aim": sim.state.player.pos + Vector2(0, -1),
			"fire": false, "switch_to": -1})
		ev.append_array(sim.drain_events())
	return ev


func _test_grid_and_content() -> void:
	var sim := _start(9101)
	_ok(sim.state.loot_boxes.size() == int(sim.cfg.num("loot", "box_count_scout", 18)),
		"搜集期箱子数量 = 配表",
		"%d" % sim.state.loot_boxes.size())
	var ok_cells := true
	var counts := []
	for i in range(sim.state.loot_boxes.size()):
		var box: Dictionary = sim.state.loot_boxes[i]
		if (box["cells"] as Array).size() != 16 or not _layout_ok(box):
			ok_cells = false
		var n := _items(box)
		counts.append(n)
		var allowed := [1, 2, 3, 4, 5, 6] if str(box["tier"]) == "common" else [3, 4, 5, 6]
		if not (n in allowed):
			ok_cells = false
	_ok(ok_cells, "每箱 16 格、占位不重叠、件数落在区间", str(counts))
	_ok(counts.count(0) == 0, "最小 1 件，不会出现空盒")

	var any_item := false
	for it in sim.state.loot_boxes[0]["items"]:
		any_item = true
		_ok(int(it["tier"]) >= 1 and int(it["tier"]) <= 5, "等级在 1–5")
		_ok(int(it["amount"]) > 0, "单件产量 > 0", str(it))
		var shape := Vector2i(int(it["w"]), int(it["h"]))
		var steps: Array = cfg.box_footprint_steps(int(it["tier"]))
		_ok(shape in steps, "占位是该等级的合法形状或降档形状",
			"tier=%d shape=%s" % [int(it["tier"]), str(shape)])
		break
	_ok(any_item, "内容确实抽出来了")

	# 占位表本身
	_ok(cfg.box_footprint(1) == Vector2i(1, 1), "1 级占 1×1")
	_ok(cfg.box_footprint(2) == Vector2i(1, 2), "2 级占 1×2")
	_ok(cfg.box_footprint(3) == Vector2i(2, 1), "3 级占 2×1")
	_ok(cfg.box_footprint(4) == Vector2i(2, 2) and cfg.box_footprint(5) == Vector2i(2, 2),
		"4/5 级占 2×2")
	_ok((cfg.box_footprint_steps(4) as Array).has(Vector2i.ONE), "2×2 放不下会降到 1×1")


func _test_determinism() -> void:
	var a := _start(9102)
	var b := _start(9102)
	var same := true
	for i in range(6):
		if str(a.state.loot_boxes[i]["cells"]) != str(b.state.loot_boxes[i]["cells"]):
			same = false
		if str(a.state.loot_boxes[i]["items"]) != str(b.state.loot_boxes[i]["items"]):
			same = false
	_ok(same, "同一局种子 + 波次 → 箱子内容完全一致（读档/重进不能重抽）")

	var before := str(a.state.loot_boxes[0]["cells"])
	_stand(a, a.state.loot_boxes[0])
	_step(a, 1.5)
	_ok(str(a.state.loot_boxes[0]["cells"]) == before, "扫描过程中内容不重抽")


func _test_scan_timing() -> void:
	var sim := _start(9103)
	var box: Dictionary = sim.state.loot_boxes[0]
	_stand(sim, box)
	sim.step(DT, {})
	_ok(sim.state.searching_box == 0, "进入范围开始搜索")
	var expect := _first_cell_time(box)
	_ok(is_equal_approx(float(box["cell_total"]), expect), "首格耗时 = 该格等级/空格时间",
		"total=%.2f expect=%.2f" % [float(box["cell_total"]), expect])

	# 空格 0.18s、1 级 0.20s 的常量
	_ok(is_equal_approx(cfg.box_cell_time({}), 0.18), "空格 0.18s")
	_ok(is_equal_approx(cfg.box_cell_time({"tier": 1}), 0.20), "1 级 0.20s")
	_ok(is_equal_approx(cfg.box_cell_time({"tier": 5}), 0.45), "5 级 0.45s")

	# 扫完一整盒：多格物品只在「锚点格」计时，占用的其余格不再耗时
	var total := _expected_box_time(box)
	var ev: Array = []
	var elapsed := 0.0
	while elapsed < total + 1.0 and not bool(box["opened"]):
		sim.step(DT, {"move": Vector2.ZERO, "aim": sim.state.player.pos + Vector2(0, -1),
			"fire": false, "switch_to": -1})
		ev.append_array(sim.drain_events())
		elapsed += DT
	_ok(int(box["pointer"]) == 16 and bool(box["opened"]), "扫完 16 格才开完",
		"pointer=%d opened=%s" % [int(box["pointer"]), str(box["opened"])])
	_ok(elapsed >= total - 0.2, "多格物品占用的格子不重复计时",
		"elapsed=%.2f expect≈%.2f" % [elapsed, total])
	_ok(sim.state.searching_box == -1, "开完后不再处于搜索状态")

	var revealed_count := 0
	for r in box["revealed"]:
		if bool(r):
			revealed_count += 1
	_ok(revealed_count == 16, "16 格全部标记为已扫", "%d" % revealed_count)
	var all_items := true
	for it in box["items"]:
		if not bool(it["revealed"]):
			all_items = false
	_ok(all_items, "所有物品都已显现")

	var opened := {}
	for e in ev:
		if String(e["type"]) == EventBus.LOOT_OPENED:
			opened = e["data"]
	_ok(not opened.is_empty(), "完成时发出 LOOT_OPENED")
	# 2026-11-15：扫描完只是显现，物资要玩家双击拾取才进背包
	for ii in range(box["items"].size()):
		sim.take_loot(0, ii)
	var gain: Dictionary = box.get("gain", {})
	var sum := int(gain.get("coin", 0)) + int(gain.get("brick", 0)) + int(gain.get("metal", 0)) + int(gain.get("ammo", 0))
	_ok(sum > 0, "拾取后收益非空", str(gain))
	_ok(sim.state.coin >= int(gain.get("coin", 0)), "金币确实入账")


## 首格耗时：命中物品用该件等级时间，空格用 empty_time
func _first_cell_time(box: Dictionary) -> float:
	var idx := int(box["cells"][0])
	if idx < 0:
		return cfg.box_empty_time()
	return cfg.box_cell_time({"tier": int(box["items"][idx]["tier"])})


## 一次完整扫描的期望耗时：每个空格 + 每件物品的锚点格（其余占用格免费）
func _expected_box_time(box: Dictionary) -> float:
	var cells: Array = box["cells"]
	var items: Array = box["items"]
	var total := 0.0
	for i in range(cells.size()):
		var idx := int(cells[i])
		if idx < 0:
			total += cfg.box_empty_time()
			continue
		var it: Dictionary = items[idx]
		if int(it["y"]) * 4 + int(it["x"]) == i:
			total += cfg.box_cell_time({"tier": int(it["tier"])})
	return total


func _test_leave_and_resume() -> void:
	var sim := _start(9104)
	var box: Dictionary = sim.state.loot_boxes[0]
	_stand(sim, box)
	_step(sim, 0.9)                       # 扫到一半
	var pointer := int(box["pointer"])
	var left := float(box["cell_left"])
	_ok(pointer >= 3 and pointer <= 6, "离开前已扫过若干格", "pointer=%d" % pointer)

	sim.state.player.pos = Vector2(0, 0)  # 走远
	sim.step(DT, {})
	_ok(sim.state.searching_box == -1, "离开后停止搜索")
	var pointer_after := int(box["pointer"])
	_ok(pointer_after == pointer, "离开不推进指针")
	_ok(is_equal_approx(float(box["cell_left"]), left), "离开保留当前格剩余时间",
		"%.3f -> %.3f" % [left, float(box["cell_left"])])

	var revealed_before := 0
	for r in box["revealed"]:
		if bool(r):
			revealed_before += 1
	_stand(sim, box)                      # 回来接着扫
	var ev := _step(sim, 6.0)
	var revealed_after := 0
	for r in box["revealed"]:
		if bool(r):
			revealed_after += 1
	_ok(revealed_after > revealed_before, "回来继续扫", "%d -> %d" % [revealed_before, revealed_after])
	_ok(bool(box["opened"]), "回来能把它扫完")
	_ok(ev.size() > 0, "继续扫描仍会产生事件")


func _test_guarded_box() -> void:
	var sim := _start(9105)
	var refined := -1
	for i in range(sim.state.loot_boxes.size()):
		if str(sim.state.loot_boxes[i]["tier"]) == "refined":
			refined = i
			break
	_ok(refined >= 0, "存在精良箱")
	var box: Dictionary = sim.state.loot_boxes[refined]
	_stand(sim, box)
	sim.step(DT, {})
	_ok(sim.state.searching_box == -1, "有驻守时不能搜索")
	# 清空驻守后再靠近就能搜
	for id in box["guard_ids"]:
		var enemy = sim.state.enemy_by_id(int(id))
		if enemy != null:
			enemy.alive = false
	sim.step(DT, {})
	_ok(sim.state.searching_box == refined, "清空驻守后可以搜索")


func _test_tables() -> void:
	# 单件产量表
	_ok(cfg.box_amount("coin", 1) == 13 and cfg.box_amount("coin", 5) == 59, "金币产量 13→59")
	_ok(cfg.box_amount("brick", 1) == 4 and cfg.box_amount("brick", 5) == 17, "砖块产量 4→17")
	_ok(cfg.box_amount("ammo", 1) == 23 and cfg.box_amount("ammo", 5) == 104, "弹药产量 23→104")
	_ok(cfg.box_amount("metal", 1) == 3 and cfg.box_amount("metal", 5) == 14, "金属产量 3→14")

	# 件数期望
	_ok(absf(cfg.expected_box_count("common") - 2.7) < 0.02, "普通箱件数期望 2.70",
		"%.2f" % cfg.expected_box_count("common"))
	_ok(absf(cfg.expected_box_count("refined") - 4.25) < 0.02, "精良箱件数期望 4.25",
		"%.2f" % cfg.expected_box_count("refined"))

	# 等级期望随波次上升；精良 = 波次+2
	var ev := func(w: int, kind: String) -> float:
		var weights: Array = cfg.box_tier_weights(w, kind)
		var total := 0.0
		for x in weights:
			total += float(x)
		var e := 0.0
		var v := [1.0, 1.5, 2.2, 3.2, 4.5]
		for i in range(weights.size()):
			e += float(weights[i]) / total * float(v[i])
		return e
	var e1: float = ev.call(1, "common")
	var e5: float = ev.call(5, "common")
	var e8: float = ev.call(8, "common")
	_ok(absf(e1 - 1.30) < 0.02, "W1 等级期望 1.30", "%.3f" % e1)
	_ok(e5 > e1 and e8 > e5, "等级期望随波次递增", "%.2f / %.2f / %.2f" % [e1, e5, e8])
	_ok(absf(e8 - 2.10) < 0.03, "W8 等级期望 ≈2.10", "%.3f" % e8)
	_ok(cfg.box_tier_weights(1, "refined") == cfg.box_tier_weights(3, "common"),
		"精良箱按 波次+2 查表（W1 用 W3 行）")

	# 单盒金币期望 ≈ 旧 common 盒（17）
	var coin_ev := 0.0
	var weights: Array = cfg.box_tier_weights(1, "common")
	var total := 0.0
	for x in weights:
		total += float(x)
	for i in range(weights.size()):
		coin_ev += float(weights[i]) / total * float(cfg.box_amount("coin", i + 1))
	var per_box: float = cfg.expected_box_count("common") * 0.4 * coin_ev
	_ok(absf(per_box - 17.0) < 4.0, "W1 普通箱金币期望 ≈ 旧值 17", "%.1f" % per_box)