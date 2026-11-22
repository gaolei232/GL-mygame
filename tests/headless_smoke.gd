extends SceneTree
## 无头冒烟（CI 入口）：固定种子跑完整一局，同一份代码永远同一结果。
## 判定：3 个固定种子各跑满 5 波并胜利；任一路径超时 / 卡阶段 / 失败 => SMOKE FAIL。
##
## 为什么固定种子（2026-11-09）：原来 sim.new_run() 不带种子，state.setup 用
## Time.get_unix_time_from_system() 播种，而自动驾驶通关率只有 67%
## => 同一个提交约 1/3 概率冒烟变红，无法当回归门禁。
## 分布层面的问题（通关率 / 时长 / 死亡）交给 tests/balance_sweep.gd，别塞进冒烟。

const DT := 1.0 / 30.0
const Pilot := preload("res://tests/autopilot.gd")
## 取自 balance_sweep 的稳定胜局种子（1003 / 2005 / 3005），改动数值后若红，
## 先看是不是真的回归，再决定换种子还是改数值。
const SEEDS := [1003, 2005, 3005]
const MAX_STEPS := 200000        # 单局上限 ≈ 6666s 模拟时间，跑到这里就是死循环
## 300s 太紧：自动驾驶在「墙血 < 70% 就切锤子修墙」分支里会冻结 260s（seed 1003 实测），
## 第 4 波合法时长达 310s。这里只抓「同一阶段永远不推进」，取 2× 实测最大值。
const STALL_LIMIT := 600.0

var cfg: ConfigDB
var failures := 0


func _init() -> void:
	cfg = ConfigDB.new()
	if not cfg.load_all():
		printerr("配置加载失败：", cfg.errors)
		quit(1)
		return

	for seed_value in SEEDS:
		_run_once(int(seed_value))

	if failures == 0:
		print("SMOKE PASS")
		quit(0)
	else:
		printerr("SMOKE FAIL：%d/%d 局未通过" % [failures, SEEDS.size()])
		print("SMOKE FAIL")
		quit(2)


func _run_once(seed_value: int) -> void:
	# 每局重建 Sim：setup() 不重置 stats/theme 等字段，复用实例会串局（见 2026-11-09 记录）
	var sim := Sim.new(cfg)
	sim.new_run(seed_value)
	sim.request("start_run")

	var steps := 0
	var last_phase := -1
	var phase_elapsed := 0.0
	var stalled := ""
	var log_lines: PackedStringArray = []

	while steps < MAX_STEPS:
		steps += 1
		phase_elapsed += DT
		if sim.state.phase != last_phase:
			last_phase = sim.state.phase
			phase_elapsed = DT
			log_lines.append("t=%6.1fs phase=%s wave=%d coin=%d brick=%d metal=%d ammo=%d" % [
				steps * DT, GameState.phase_name(sim.state.phase), sim.state.wave_index,
				sim.state.coin, sim.state.brick, sim.state.metal, sim.state.ammo])
		elif phase_elapsed > STALL_LIMIT:
			stalled = "卡阶段：%s 停留 %.0fs" % [GameState.phase_name(sim.state.phase), phase_elapsed]
			break
		if sim.state.phase in [GameState.Phase.VICTORY, GameState.Phase.DEFEAT]:
			break
		sim.step(DT, Pilot.cmd(sim))
		sim.drain_events()

	print("[seed %d]" % seed_value)
	print("  " + "\n  ".join(log_lines))

	var reached_end: bool = sim.state.phase in [GameState.Phase.VICTORY, GameState.Phase.DEFEAT]
	var victory := sim.state.phase == GameState.Phase.VICTORY
	var reason := ""
	if stalled != "":
		reason = stalled
	elif not reached_end:
		reason = "超时：%d 步内未结束（%s）" % [MAX_STEPS, GameState.phase_name(sim.state.phase)]
	elif not victory:
		reason = "失败：第 %d 波团灭" % sim.state.wave_index

	print("  RESULT seed=%d phase=%s wave=%d kills=%d deaths=%d wall_breached=%d crystal=%.0f ammo=%d min=%.1f" % [
		seed_value, GameState.phase_name(sim.state.phase), sim.state.wave_index,
		int(sim.state.stats["kills"]), int(sim.state.stats["deaths"]),
		sim.state.wall_breached_count(), sim.state.crystal_hp, sim.state.ammo,
		steps * DT / 60.0])
	if reason != "":
		failures += 1
		printerr("  [seed %d] FAIL %s" % [seed_value, reason])