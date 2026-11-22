class_name PhaseMachine
extends RefCounted
## 阶段机：唯一的阶段切换入口。
## 规则：任何系统不得直接改 state.phase，必须走 enter()，保证进入/退出清理成对执行。

static func enter(state: GameState, next: int, cfg: ConfigDB, bus: EventBus) -> void:
	var prev := state.phase
	if prev == next:
		return
	_exit(state, prev, cfg, bus)
	state.phase = next
	state.phase_time = 0.0
	state.phase_duration = 0.0
	state.notice = ""
	state.notice_timer = 0.0

	match next:
		GameState.Phase.SCOUT:
			state.phase_duration = cfg.num("phases", "scout_seconds", 90.0)
			ScoutSystem.begin(state, cfg, bus)
		GameState.Phase.BUILD:
			state.shop_refresh_used = false
			state.wall_built_this_wave = 0      # 每波 1 段城墙的闸门按波重置
			EconomySystem.roll_shop(state, cfg)
			GuardSystem.refresh(state, cfg, bus)
			state.enemies.clear()
			state.player.pos = GameState.spawn_point(cfg)
		GameState.Phase.WAVE:
			WaveSystem.start(state, cfg, bus)
		GameState.Phase.REWARD:
			RewardSystem.prepare(state, cfg)
		GameState.Phase.VICTORY, GameState.Phase.DEFEAT:
			state.phase_duration = 0.0
			bus.emit(EventBus.RUN_ENDED, {"victory": next == GameState.Phase.VICTORY})

	bus.emit(EventBus.PHASE_CHANGED, {"from": prev, "to": next, "name": GameState.phase_name(next)})


static func _exit(state: GameState, prev: int, cfg: ConfigDB, bus: EventBus) -> void:
	match prev:
		GameState.Phase.SCOUT:
			state.loot_boxes.clear()
			state.enemies.clear()
			state.searching_box = -1
			state.near_box = -1
		GameState.Phase.WAVE:
			state.spawn_queue.clear()
			state.summon_pending.clear()


## 阶段推进：只处理计时与自动跳转，具体玩法在各自系统里
static func step(state: GameState, dt: float, cfg: ConfigDB, bus: EventBus) -> void:
	match state.phase:
		GameState.Phase.SCOUT:
			state.phase_time += dt
			if state.phase_time >= state.phase_duration:
				enter(state, GameState.Phase.BUILD, cfg, bus)
		GameState.Phase.BUILD:
			state.phase_time += dt
		GameState.Phase.WAVE:
			state.phase_time += dt
			if state.crystal_hp <= 0.0:
				enter(state, GameState.Phase.DEFEAT, cfg, bus)
		GameState.Phase.REWARD:
			state.phase_time += dt
		_:
			pass


## 玩家主动请求的阶段推进
static func request(state: GameState, action: String, cfg: ConfigDB, bus: EventBus) -> void:
	match action:
		"start_run":
			if state.phase == GameState.Phase.TITLE:
				state.wave_index = 1
				enter(state, GameState.Phase.SCOUT, cfg, bus)
		"return_city":
			if state.phase == GameState.Phase.SCOUT:
				enter(state, GameState.Phase.BUILD, cfg, bus)
		"start_wave":
			if state.phase == GameState.Phase.BUILD:
				enter(state, GameState.Phase.WAVE, cfg, bus)
		"next_round":
			if state.phase == GameState.Phase.REWARD:
				if state.wave_index >= 5:
					enter(state, GameState.Phase.VICTORY, cfg, bus)
				else:
					state.wave_index += 1
					enter(state, GameState.Phase.SCOUT, cfg, bus)
