extends SceneTree
## P1-5 数值跑批：多种子 × 多局，用同一套自动驾驶策略，输出可判读的指标表。
## 达标区间（文档 §P1-5）：通关率 60%–90%、单局 15–20 分钟、第 3 波前死亡 ≤2 次。

const DT := 1.0 / 30.0
const Pilot := preload("res://tests/autopilot.gd")
const MAX_STEPS := 220000
const SEEDS := [1001, 2002, 3003]
const RUNS_PER_SEED := 5

var cfg: ConfigDB
var rows: Array = []


func _init() -> void:
	cfg = ConfigDB.new()
	if not cfg.load_all():
		printerr("配置加载失败：", cfg.errors)
		quit(1)
		return

	for seed_value in SEEDS:
		for run in range(RUNS_PER_SEED):
			rows.append(_run_once(int(seed_value) + run))

	_report()
	quit(0)


func _run_once(run_seed: int) -> Dictionary:
	var sim := Sim.new(cfg)
	sim.new_run(run_seed)
	sim.request("start_run")
	var steps := 0
	var deaths_before_w3 := 0
	var w3_marked := false
	while steps < MAX_STEPS:
		steps += 1
		if sim.state.wave_index >= 3 and not w3_marked:
			w3_marked = true
			deaths_before_w3 = int(sim.state.stats["deaths"])
		match sim.state.phase:
			GameState.Phase.VICTORY, GameState.Phase.DEFEAT:
				break
		sim.step(DT, Pilot.cmd(sim))
		sim.drain_events()
	var minutes := steps * DT / 60.0
	return {
		"seed": run_seed,
		"victory": sim.state.phase == GameState.Phase.VICTORY,
		"minutes": minutes,
		"wave": sim.state.wave_index,
		"deaths": int(sim.state.stats["deaths"]),
		"deaths_before_w3": deaths_before_w3 if w3_marked else int(sim.state.stats["deaths"]),
		"breaches": sim.state.wall_breached_count(),
		"ammo_end": sim.state.ammo,
		"brick_end": sim.state.brick,
		"coin_end": sim.state.coin,
		"kills": int(sim.state.stats["kills"]),
		"crystal": sim.state.crystal_hp,
	}


func _report() -> void:
	print("seed  | win | min  | wave | kill | death | d<w3 | breach | ammo | brick | coin")
	var wins := 0
	var minutes := 0.0
	for r in rows:
		if bool(r["victory"]):
			wins += 1
		minutes += float(r["minutes"])
		print("%5d | %3s | %4.1f | %4d | %4d | %5d | %4d | %6d | %4d | %5d | %4d" % [
			int(r["seed"]), "Y" if bool(r["victory"]) else "N", float(r["minutes"]),
			int(r["wave"]), int(r["kills"]), int(r["deaths"]), int(r["deaths_before_w3"]),
			int(r["breaches"]), int(r["ammo_end"]), int(r["brick_end"]), int(r["coin_end"])])

	var n := maxi(1, rows.size())
	var win_rate := float(wins) / float(n)
	var avg_min := minutes / float(n)
	print("---- SUMMARY ----")
	print("runs=%d win_rate=%.0f%% avg_minutes=%.1f" % [n, win_rate * 100.0, avg_min])
	print("target: win 60–90%%, 15–20 min, deaths before wave3 <= 2")
	var ok := win_rate >= 0.6 and win_rate <= 0.9 and avg_min >= 15.0 and avg_min <= 20.0
	print("SWEEP %s" % ("PASS" if ok else "CHECK"))
