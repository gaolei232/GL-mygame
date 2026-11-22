class_name Sim
extends RefCounted
## 核心层门面（core 的唯一对外 API）：装配配置、状态、事件，按固定顺序推进一帧。
## 分层规则：view/ui/app 只允许调用 Sim 的这 4 个方法，不得直接改 GameState。

var cfg: ConfigDB
var state: GameState
var bus: EventBus


func _init(config: ConfigDB = null) -> void:
	cfg = config if config != null else ConfigDB.new()
	if cfg.balance.is_empty():
		cfg.load_all()
	state = GameState.new()
	state.setup(cfg)
	bus = EventBus.new()
	GuardSystem.refresh(state, cfg, bus)


func new_run(run_seed: int = 0) -> void:
	state.setup(cfg, run_seed)
	bus.clear()
	state.phase = GameState.Phase.TITLE
	GuardSystem.refresh(state, cfg, bus)


func request(action: String) -> void:
	PhaseMachine.request(state, action, cfg, bus)


## 双击拾取箱内物资（2026-11-15）：item_index >= 0 取格子物品，-1 取精良箱词条。
## ui 只读 snapshot，所以拾取这个「带参数的写操作」必须走门面，不能直接改 state。
func take_loot(box_index: int, item_index: int) -> bool:
	return ScoutSystem.take(state, cfg, bus, box_index, item_index)


## 丢弃背包物品（背包满时腾格子用）。
func drop_item(uid: int) -> bool:
	return InventorySystem.drop_uid(state, uid)


func step(dt: float, cmd: Dictionary = {}) -> void:
	state.notice_timer = maxf(0.0, state.notice_timer - dt)
	state.crystal_hit_flash = maxf(0.0, state.crystal_hit_flash - dt)
	state.player.hurt_flash = maxf(0.0, state.player.hurt_flash - dt)
	for seg in state.wall:
		if seg.hit_flash > 0.0:
			seg.hit_flash = maxf(0.0, seg.hit_flash - dt)

	match state.phase:
		GameState.Phase.SCOUT:
			ScoutSystem.step(state, dt, cfg, bus)
		GameState.Phase.WAVE:
			WaveSystem.step(state, dt, cfg, bus)
			GuardSystem.step(state, dt, cfg, bus)
		_:
			pass

	# 玩家系统在搜集/建设/战斗三阶段都跑：建设期也能开火/修墙（2026-11-08 改），
	# 但建设期的活动范围被 PlayerSystem 限制在城墙圈内，不能提前出城。
	if state.phase in [GameState.Phase.SCOUT, GameState.Phase.BUILD, GameState.Phase.WAVE]:
		PlayerSystem.step(state, dt, cfg, bus, cmd)

	# 建造系统放在玩家移动之后：掉落回收用本帧位置，炮台在敌人移动后开火。
	# 奖励/结算阶段也跑：掉落的 60s 计时不能因为阶段切换而暂停。
	if state.phase != GameState.Phase.TITLE:
		BuildSystem.step(state, dt, cfg, bus)

	PhaseMachine.step(state, dt, cfg, bus)

	if state.crystal_hp <= 0.0 and state.phase != GameState.Phase.DEFEAT:
		state.crystal_hp = 0.0
		PhaseMachine.enter(state, GameState.Phase.DEFEAT, cfg, bus)


func drain_events() -> Array:
	return bus.drain()


func snapshot() -> Dictionary:
	return state.snapshot()


func notice(text: String) -> void:
	state.notice = text
	state.notice_timer = 2.2
