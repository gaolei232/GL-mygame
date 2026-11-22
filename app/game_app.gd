class_name GameApp
extends Node3D
## 编排层：唯一允许同时接触 core 与 view/ui 的地方。
## 职责三件事：把输入翻译成 core 命令；把 core 事件翻译成表现；把快照推给视图。
## 禁止：在这里写玩法规则（命中、伤害、经济、阶段判断都必须在 core）。

## P0-9：单存档位，自动存于安全阶段。`save_path` 可被测试覆盖（沙箱下 user:// 不可写）
const SAVE_PATH := "user://save_slot1.json"
## P1-2：设置与存档分开存，避免读档时连带覆盖音量/画质
const SETTINGS_PATH := "user://settings.json"
var save_path := SAVE_PATH
var settings_path := SETTINGS_PATH

var sim: Sim
var world: WorldBuilder
var units: UnitLayer
var cam: CameraRig
var fx: FxLayer
var audio: AudioLayer
var hud: Hud
var menu: MainMenu
var pause: PauseMenu
var settings: SettingsPanel
var odds: OddsPanel
var search: SearchPanel
var bag: InventoryPanel
var build_layer: BuildLayer
var build_panel: BuildPanel
var crate_panel: CratePanel
var _build_selected := ""
var _last_build_id := "crate"
var _demolish_mode := false
var _build_info: Dictionary = {}

var _down: Dictionary = {}
var _sprint := false
var _blink := false
var _q_prev := false
var help: Control
var _focus_aim := false
var _fire_buffer := 0.0        # 点击缓冲：避免「按下+松开」落在两帧之间时丢枪
var _roll_buffer := 0.0        # 右键缓冲：翻滚是点按，不是按住
var _ui_scale := 1.0
var _aim := Vector2.ZERO       # 本帧光标地面点（墙段悬停与提示共用）
var _hover_wall := -1          # 建设期光标命中的墙段索引，-1 = 没指到墙
var _hitstop := 0.0            # 击杀顿帧剩余秒数（P0-3）：只冻结 sim，不冻结特效与镜头
var _heartbeat_cd := 0.0       # 残血心跳的节拍（P0-8）
var _paused := false
var _settings := {"volume": 0.8, "fullscreen": false, "quality": 1}


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	sim = Sim.new()
	if not sim.cfg.errors.is_empty():
		for e in sim.cfg.errors:
			push_warning("[core] " + e)
	sim.new_run()

	world = WorldBuilder.new()
	add_child(world)
	units = UnitLayer.new()
	add_child(units)
	build_layer = BuildLayer.new()
	add_child(build_layer)
	fx = FxLayer.new()
	add_child(fx)
	fx.setup()
	audio = AudioLayer.new()
	add_child(audio)
	audio.setup()
	cam = CameraRig.new()
	add_child(cam)
	cam.setup(sim.cfg)
	units.setup()

	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Hud.new()
	layer.add_child(hud)
	# 主菜单叠在 HUD 之上，只在 TITLE 阶段显示（2026-11-08）
	menu = MainMenu.new()
	layer.add_child(menu)
	pause = PauseMenu.new()
	layer.add_child(pause)
	settings = SettingsPanel.new()
	layer.add_child(settings)
	odds = OddsPanel.new()
	layer.add_child(odds)
	help = preload("res://ui/help_panel.gd").new()
	layer.add_child(help)
	help.closed.connect(func(): pass)
	search = SearchPanel.new()
	layer.add_child(search)
	bag = InventoryPanel.new()
	layer.add_child(bag)
	build_panel = BuildPanel.new()
	layer.add_child(build_panel)
	crate_panel = CratePanel.new()
	layer.add_child(crate_panel)
	# 背包必须在 HUD 之上、暂停/设置/概率公示之下
	menu.start_requested.connect(_on_menu_start)
	menu.continue_requested.connect(_on_continue)
	menu.settings_requested.connect(_open_settings)
	menu.odds_requested.connect(_open_odds)
	menu.quit_requested.connect(func(): get_tree().quit())
	pause.resume_requested.connect(func(): set_paused(false))
	pause.settings_requested.connect(_open_settings)
	pause.odds_requested.connect(_open_odds)
	pause.title_requested.connect(_return_to_title)
	settings.closed.connect(_close_settings)
	settings.changed.connect(_on_settings_changed)
	odds.closed.connect(_close_odds)
	# 箱子里的物资要玩家双击才进背包（2026-11-15）
	search.loot_take_requested.connect(func(box_index: int, item_index: int):
		if sim != null:
			sim.take_loot(box_index, item_index))
	# 背包物品丢弃（资源不可卖出，右键丢弃腾格子）
	bag.drop_requested.connect(func(uid: int):
		if sim != null:
			sim.drop_item(uid))

	_settings = _read_settings()
	_apply_settings(_settings)

	world.build(sim.cfg, sim.snapshot())
	cam.follow(sim.state.player.pos, 0.0, true)
	_sync_continue_button()

	hud.request_action.connect(_on_action)
	hud.request_buy.connect(_on_buy)
	hud.request_equip_weapon.connect(_on_equip_weapon)
	hud.request_refresh.connect(_on_refresh)
	hud.request_crystal_upgrade.connect(_on_crystal_upgrade)
	hud.request_weapon_upgrade.connect(_on_weapon_upgrade)
	hud.request_pick.connect(_on_pick)
	hud.request_equip.connect(_on_equip)
	hud.request_unequip.connect(_on_unequip)
	hud.request_sell.connect(_on_sell)
	hud.request_bag.connect(_toggle_bag)
	bag.equip_requested.connect(_on_equip)
	bag.unequip_requested.connect(_on_unequip)
	bag.sell_requested.connect(_on_sell)
	build_panel.build_requested.connect(_on_build_requested)
	build_panel.free_build_toggled.connect(_on_free_build_toggled)
	build_panel.demolish_toggled.connect(_on_demolish_toggled)
	crate_panel.deposit_item.connect(_on_crate_deposit_item)
	crate_panel.withdraw_slot.connect(_on_crate_withdraw_slot)
	crate_panel.deposit_resource.connect(_on_crate_deposit_resource)
	crate_panel.withdraw_resource.connect(_on_crate_withdraw_resource)
	crate_panel.deposit_all_items.connect(_on_crate_deposit_all)
	crate_panel.closed.connect(_close_crate)
	_refresh_costs()
	_apply_events(sim.drain_events())


func _process(delta: float) -> void:
	_fire_buffer = maxf(0.0, _fire_buffer - delta)
	_roll_buffer = maxf(0.0, _roll_buffer - delta)
	# 击杀顿帧：冻结玩法 1–2 帧，让「打中了」有重量（P0-3）。
	# 用真实时间递减，不能用 sim 的 dt——否则 dt=0 时永远出不来。
	# 暂停/设置同样只冻结 sim（表现为「世界停住」），UI 与输入照常。
	var frozen := _paused or settings.visible or odds.visible or bag.visible \
		or crate_panel.visible or (help != null and help.visible)
	var sim_dt := delta
	if _hitstop > 0.0:
		_hitstop = maxf(0.0, _hitstop - delta)
		sim_dt = 0.0
	if frozen:
		sim_dt = 0.0
		pause.visible = _paused
	var in_title := sim.state.phase == GameState.Phase.TITLE
	menu.visible = in_title
	hud.visible = not in_title
	# 覆盖层开着时禁掉主菜单键盘，避免 F/Enter 穿透到「开始游戏」
	menu.input_enabled = not (settings.visible or odds.visible)
	var cmd := {}
	if not frozen:
		cmd = _read_input()
	sim.step(sim_dt, cmd)
	# 事件必须在本帧 sync 之前消费：否则「中弹闪白」要等下一帧才上色，
	# 反馈永远慢 16ms（2026-11-09 做 P0-3 时抓包发现）
	_apply_events(sim.drain_events())
	_tick_heartbeat(delta, frozen)
	var snap := sim.snapshot()
	_build_info = BuildSystem.ui_state(sim.state, sim.cfg, _build_selected, _aim, _demolish_mode)

	# 建设期/战斗期：光标指到哪段墙，就高亮并提示（P0-7 升级 / 破口重建）
	_hover_wall = -1
	if not frozen and sim.state.phase in [GameState.Phase.BUILD, GameState.Phase.WAVE]:
		if _demolish_mode and sim.state.phase == GameState.Phase.BUILD:
			var target: Dictionary = _build_info.get("demolish_target", {})
			if String(target.get("kind", "")) == "wall":
				_hover_wall = int(target.get("index", -1))
		else:
			_hover_wall = sim.state.wall_segment_at(_aim, 2.5, true)
	world.set_wall_hover(_hover_wall)
	hud.set_wall_hint(_wall_hint())

	world.sync_walls(snap)
	world.sync_crystal(snap)
	units.sync(snap, delta)
	build_layer.sync(snap, delta)
	# 放置预览：位置非法时变红，合法时绿色
	if _build_selected != "" and _build_selected != "backpack" \
			and sim.state.phase == GameState.Phase.BUILD and not frozen:
		var check := BuildSystem.can_build(sim.state, sim.cfg, _build_selected, _aim)
		build_layer.set_ghost(_build_selected, _aim, bool(check["ok"]))
	else:
		build_layer.set_ghost("", Vector2.ZERO, false)
	# 拆除模式：悬停的建造物亮红框（城墙高亮由 world 负责）
	var demo_target: Dictionary = _build_info.get("demolish_target", {})
	if _demolish_mode and String(demo_target.get("kind", "")) == "building":
		build_layer.set_hover(int(demo_target.get("id", -1)))
	else:
		build_layer.set_hover(-1)
	# 建造面板只在建设期常驻；背包/仓库/暂停时让位
	var show_build := sim.state.phase == GameState.Phase.BUILD and not frozen
	build_panel.visible = show_build
	if show_build:
		build_panel.sync(snap, _build_info)
	if crate_panel.visible:
		crate_panel.sync(snap)
	cam.follow(sim.state.player.pos, delta)
	cam.set_focus_aim(_focus_aim)
	world.update_occlusion(cam.camera.global_position, sim.state.player.pos)
	hud.set_focus_aim(_focus_aim)
	fx.tick(delta)
	hud.update_snapshot(snap)
	search.sync_from(snap)



func _read_input() -> Dictionary:
	var move := Vector2.ZERO
	var fwd3 := -cam.camera.global_basis.z
	var right3 := cam.camera.global_basis.x
	var fwd := Vector2(fwd3.x, fwd3.z).normalized()
	var right := Vector2(right3.x, right3.z).normalized()
	if Input.is_physical_key_pressed(KEY_W):
		move += fwd
	if Input.is_physical_key_pressed(KEY_S):
		move -= fwd
	if Input.is_physical_key_pressed(KEY_D):
		move += right
	if Input.is_physical_key_pressed(KEY_A):
		move -= right

	var aim := cam.ground_point(get_viewport().get_mouse_position())
	_aim = aim

	var switch_to := -1
	for i in range(4):
		if _just(KEY_1 + i):
			switch_to = i

	# 建造快捷键：V 自由建造模式；5 木箱 / 6 背包 / 7 城墙 / 8 炮台；X 拆除；R 木箱仓库
	if _just(KEY_5):
		_on_build_requested("crate")
	if _just(KEY_6):
		_on_build_requested("backpack")
	if _just(KEY_7):
		_on_build_requested("wall")
	if _just(KEY_8):
		_on_build_requested("cannon")
	if _just(KEY_X):
		_on_demolish_toggled(not _demolish_mode)
	if _just(KEY_V):
		_toggle_free_build()
	if _just(KEY_R):
		_toggle_crate()


	# 墙段交互（P0-7 / 建造）：破口按 E 重建（建设期与战斗期），完好段只在建设期升级；
# 光标不在任何墙段上时，建设期按 E 在光标处新建一段（每波 1 段，靠造价与名额做闸门）
	if _just(KEY_E) and _build_selected == "" and not _demolish_mode:
		if _hover_wall >= 0:
			var seg: GameState.WallSegment = sim.state.wall[_hover_wall]
			if seg.breached:
				EconomySystem.rebuild_wall(sim.state, sim.cfg, sim.bus, _hover_wall)
			elif sim.state.phase == GameState.Phase.BUILD:
				EconomySystem.upgrade_wall(sim.state, sim.cfg, sim.bus, _hover_wall)
		elif sim.state.phase == GameState.Phase.BUILD:
			EconomySystem.build_wall(sim.state, sim.cfg, sim.bus, _aim)

	if _just(KEY_F):
		match sim.state.phase:
			GameState.Phase.TITLE:
				sim.request("start_run")
			GameState.Phase.SCOUT:
				sim.request("return_city")
			GameState.Phase.BUILD:
				_cancel_build_mode()
				sim.request("start_wave")

	_focus_aim = Input.is_physical_key_pressed(KEY_SPACE)
	_sprint = Input.is_physical_key_pressed(KEY_SHIFT)

	# Q 是瞬时技能，必须边沿触发：按住不放不能连发
	var q_now := Input.is_physical_key_pressed(KEY_Q)
	_blink = q_now and not _q_prev
	_q_prev = q_now
	var fire := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if _build_selected != "" or _demolish_mode:
		fire = false           # 建造/拆除模式下左键是「放置/拆除」，不能顺带开枪
	if not fire and _fire_buffer > 0.0:
		fire = true
		_fire_buffer = 0.0     # 缓冲只用一次，避免连发
	# 主菜单上不接开火（点「开始游戏」那一下不该带出一枪）
	if sim.state.phase == GameState.Phase.TITLE:
		fire = false

	var roll := _roll_buffer > 0.0
	_roll_buffer = 0.0

	return {
		"move": move,
		"aim": aim,
		"focus_aim": _focus_aim,
		"sprint": _sprint,
		"blink": _blink,
		"fire": fire,
		"roll": roll,
		"action": false,
		"switch_to": switch_to,
	}


func _just(code: int) -> bool:
	var now := Input.is_physical_key_pressed(code)
	var was: bool = _down.get(code, false)
	_down[code] = now
	return now and not was


## 覆盖层的 Esc 必须在 `_input` 里吃掉：`_unhandled_input` 谁先收到取决于节点顺序，
## 主菜单会把 Esc 当「退出游戏」——曾在概率公示里按 Esc 直接把游戏关了。
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).physical_keycode == KEY_ESCAPE and (odds.visible or settings.visible):
			_close_odds()
			_close_settings()
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var k := (event as InputEventKey).physical_keycode
		# 全屏覆盖层的 Esc 优先级：概率公示 > 设置 > 主菜单 > 暂停
		if odds.visible and k == KEY_ESCAPE:
			_close_odds()
			get_viewport().set_input_as_handled()
			return
		if settings.visible and k == KEY_ESCAPE:
			_close_settings()
			get_viewport().set_input_as_handled()
			return
		# 主菜单可见时放手让 MainMenu 自己处理 Esc（它负责退出游戏）
		if menu.visible:
			return
		# 木箱仓库：R / Esc / B 关闭；其他键在模态期间一律吃掉，避免 P 把暂停面板叠在仓库下面
		if crate_panel.visible:
			if k == KEY_ESCAPE or k == KEY_R or k == KEY_B or k == KEY_TAB:
				_close_crate()
			get_viewport().set_input_as_handled()
			return
		# 建造/拆除模式：Esc 先取消，不要直接弹暂停
		if (_build_selected != "" or _demolish_mode) and k == KEY_ESCAPE:
			_cancel_build_mode()
			get_viewport().set_input_as_handled()
			return
		# 背包（B / Tab）：开着就关，关着就开；暂停中不响应
		if help.visible and (k == KEY_ESCAPE or k == KEY_H):
			help.call("close")
			get_viewport().set_input_as_handled()
			return
		if k == KEY_H and not _paused:
			help.call("open")
			get_viewport().set_input_as_handled()
			return
		if bag.visible and (k == KEY_ESCAPE or k == KEY_B or k == KEY_TAB):
			bag.close()
			get_viewport().set_input_as_handled()
			return
		if (k == KEY_B or k == KEY_TAB) and not _paused:
			_toggle_bag()
			get_viewport().set_input_as_handled()
			return
		if k == KEY_ESCAPE and not settings.visible:
			set_paused(not _paused)
			get_viewport().set_input_as_handled()
			return
		if k == KEY_P and not settings.visible:
			set_paused(not _paused)
			get_viewport().set_input_as_handled()
			return
	if _paused or settings.visible:
		return                     # 暂停/设置时不接受镜头缩放与开火缓冲
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam.zoom_by(-1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam.zoom_by(1.0)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			# 光标压在按钮上时左键归 UI：不打枪，只给一次点击反馈（§7.1 光标规则）
			_on_left_click(event.position, _hovered_button() != null)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			# 建造/拆除模式下右键 = 取消；否则右键 = 翻滚（点按）
			if _build_selected != "" or _demolish_mode:
				_cancel_build_mode()
			elif _hovered_button() == null:
				_roll_buffer = 0.12


## 左键语义分流（拆出来是为了能测：UI 点击不能带出一枪）
func _on_left_click(pos: Vector2, over_button: bool) -> void:
	if over_button:
		hud.pulse_click(pos)
		return
	# 建造面板/仓库的空白区域也算 UI：点卡片之间的缝不能顺手放一个建筑/开一枪
	if _ui_blocks_click(pos):
		return
	if _build_selected != "":
		_place_selected()
		return
	if _demolish_mode:
		_demolish_at_aim()
		return
	# 事件级开火缓冲：即使这一帧的轮询没抓到按下状态，也不会丢这一枪
	_fire_buffer = 0.12


func _ui_blocks_click(pos: Vector2) -> bool:
	if hud != null and hud.blocks_shop_click(pos):
		return true
	if build_panel != null and build_panel.visible \
			and build_panel.get_global_rect().has_point(pos):
		return true
	if crate_panel != null and crate_panel.visible \
			and crate_panel.get_global_rect().has_point(pos):
		return true
	return false


## 光标当前压在哪个按钮上（含按钮里的子 Label）；没有则返回 null
func _hovered_button() -> BaseButton:
	var c: Control = get_viewport().gui_get_hovered_control()
	while c != null:
		if c is BaseButton:
			return c as BaseButton
		c = c.get_parent_control()
	return null


## 主菜单 → 开局：清掉点击缓冲，避免「开始游戏」那一下带出一枪/一滚
func _on_menu_start() -> void:
	_fire_buffer = 0.0
	_roll_buffer = 0.0
	_cancel_build_mode()
	_last_build_id = "crate"
	_close_crate()
	_close_settings()
	_close_odds()
	_clear_save()                  # 新开局作废旧存档，避免「继续」加载上一局
	build_layer.reset()
	sim.request("start_run")


# ------------------------------------------------------------------ 存档（P0-9）
# 口径：只在 SCOUT / BUILD / REWARD 三个阶段切换时自动落盘（见 SaveSystem 说明）。
# 战斗期退出 = 回到本波最近的安全阶段，会重打这一波。

func _read_save() -> Dictionary:
	if not FileAccess.file_exists(save_path):
		return {}
	var f := FileAccess.open(save_path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _write_save() -> void:
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		push_warning("[save] 无法写入 " + save_path)
		return
	f.store_string(JSON.stringify(SaveSystem.capture(sim.state)))
	f.close()
	_sync_continue_button()


func _clear_save() -> void:
	var dir := DirAccess.open("user://")
	if dir != null:
		dir.remove(save_path.get_file())
	menu.set_can_continue(false)


## 主菜单「继续」按钮：有存档才显示，并把阶段与波次写在按钮上
func _sync_continue_button() -> void:
	var data := _read_save()
	if data.is_empty():
		menu.set_can_continue(false)
		return
	menu.set_can_continue(true, "%s · 第 %d 波" % [
		GameState.phase_name(int(data.get("phase", GameState.Phase.TITLE))),
		int(data.get("wave_index", 1))])


func _on_continue() -> void:
	var data := _read_save()
	if data.is_empty() or not SaveSystem.restore(sim.state, sim.cfg, sim.bus, data):
		_clear_save()
		return
	_close_settings()
	_close_odds()
	_fire_buffer = 0.0
	_roll_buffer = 0.0
	_hitstop = 0.0
	_hover_wall = -1
	_cancel_build_mode()
	_last_build_id = "crate"
	_close_crate()
	bag.close()
	build_layer.reset()
	world.build(sim.cfg, sim.snapshot())
	cam.follow(sim.state.player.pos, 0.0, true)
	hud.invalidate()
	_refresh_costs()
	_apply_events(sim.drain_events())


# ------------------------------------------------------------------ 暂停与设置（P1-1 / P1-2）

func set_paused(on: bool) -> void:
	if sim.state.phase == GameState.Phase.TITLE:
		on = false
	_paused = on
	pause.visible = on
	if on:
		# 暂停时退出建造/拆除，关掉背包/仓库，回来不会残留一个「看不见的放置模式」
		_cancel_build_mode()
		_close_crate()
		bag.close()
		hud.set_wall_hint("")


func _toggle_bag() -> void:
	if sim.state.phase == GameState.Phase.TITLE or _paused:
		return
	if bag.visible:
		bag.close()
		return
	_cancel_build_mode()
	_close_crate()
	_close_settings()
	_close_odds()
	bag.open(sim.snapshot())


func _open_settings() -> void:
	_close_odds()
	settings.open(_settings)


func _close_settings() -> void:
	settings.close()


## 概率公示（P1-6）：数据全部来自 ConfigDB（= data/items.json），面板只负责排版
func _open_odds() -> void:
	settings.close()
	odds.open(_odds_data())


func _close_odds() -> void:
	odds.close()


func _odds_data() -> Dictionary:
	var tiers: Array = []
	for row in sim.cfg.rarity_rows():
		tiers.append({
			"name": str(row.get("name", "?")), "mult": float(row.get("mult", 1.0)),
			"sell": int(row.get("sell", 0)), "color": str(row.get("color", "#ffffff")),
		})
	var waves: Array = []
	var weights: Array = []
	for wave in range(1, 6):
		waves.append("第 %d 波" % wave)
		var row_weights: Array = []
		for w in sim.cfg.tier_weights(wave):
			row_weights.append(int(w))        # JSON 数字是 float，公示页按整数呈现
		weights.append(row_weights)
	var items: Array = []
	for d in sim.cfg.item_defs():
		items.append({
			"name": str(d.get("name", "?")), "kind": str(d.get("kind", "trait")),
			"desc": str(d.get("desc", "")), "base": float(d.get("base", 0.0)),
		})
	return {"tiers": tiers, "waves": waves, "weights": weights, "items": items}


func _on_settings_changed(values: Dictionary) -> void:
	_settings = _sanitize_settings(values)
	_apply_settings(_settings)
	_write_settings()


## 暂停菜单「返回主菜单」：内存重置到 TITLE，**不动存档文件**——回来还能「继续」
func _return_to_title() -> void:
	set_paused(false)
	_close_settings()
	_close_odds()
	_hitstop = 0.0
	_hover_wall = -1
	_cancel_build_mode()
	_last_build_id = "crate"
	_close_crate()
	sim.new_run()
	build_layer.reset()
	world.build(sim.cfg, sim.snapshot())
	cam.follow(sim.state.player.pos, 0.0, true)
	hud.invalidate()
	_sync_continue_button()


func _read_settings() -> Dictionary:
	if not FileAccess.file_exists(settings_path):
		return _sanitize_settings({})
	var f := FileAccess.open(settings_path, FileAccess.READ)
	if f == null:
		return _sanitize_settings({})
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return _sanitize_settings(parsed if parsed is Dictionary else {})


func _write_settings() -> void:
	var f := FileAccess.open(settings_path, FileAccess.WRITE)
	if f == null:
		push_warning("[settings] 无法写入 " + settings_path)
		return
	f.store_string(JSON.stringify(_settings))
	f.close()


## 越界值一律夹回合法范围：手改配置文件不该把画质设成 99
func _sanitize_settings(v: Dictionary) -> Dictionary:
	return {
		"volume": clampf(float(v.get("volume", 0.8)), 0.0, 1.0),
		"fullscreen": bool(v.get("fullscreen", false)),
		"quality": clampi(int(v.get("quality", 1)), 0, 2),
	}


## 音量走 AudioServer（P0-8 音频接进来即生效）；画质只有 MSAA 一档可调，不假装有更多
func _apply_settings(v: Dictionary) -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(0.0001, float(v["volume"]))))
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(
			DisplayServer.WINDOW_MODE_FULLSCREEN if bool(v["fullscreen"])
			else DisplayServer.WINDOW_MODE_WINDOWED)
	var modes := [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X]
	get_viewport().msaa_3d = modes[clampi(int(v["quality"]), 0, 2)]


## 残血心跳（P0-8）：HP < 30% 时 0.9s 一跳——「你快死了」唯一的非视觉信号，
## 低头看血条是最容易在混战里忘掉的动作。脱险即重置，下次进危险立刻响。
func _tick_heartbeat(delta: float, frozen: bool) -> void:
	var p := sim.state.player
	var danger := not frozen and p.alive \
		and p.hp / maxf(1.0, p.max_hp) < 0.3 \
		and sim.state.phase in [GameState.Phase.SCOUT, GameState.Phase.BUILD, GameState.Phase.WAVE]
	if not danger:
		_heartbeat_cd = 0.0
		return
	_heartbeat_cd = maxf(0.0, _heartbeat_cd - delta)
	if _heartbeat_cd <= 0.0:
		audio.play("heartbeat")
		_heartbeat_cd = 0.9


func _apply_events(events: Array) -> void:
	for ev in events:
		var data: Dictionary = ev.get("data", {})
		match str(ev["type"]):
			EventBus.SHOT_FIRED:
				var kind := str(data.get("kind", "crossbow"))
				var melee := kind in ["knife", "longsword"]
				fx.add_tracer(data["from"], data["to"],
					Color(0.80, 0.90, 1.0) if melee else Color(1.0, 0.92, 0.65))
				audio.play("knife" if melee else "shot")
				var p := sim.state.player
				units.play_player_fire(kind, p.melee_cd if melee else p.fire_cd)
			EventBus.ENEMY_HIT:
				# 中弹闪白 + 火花 + 飘字。ENEMY_HIT 原来全工程无人消费，打中没有任何反馈（P0-3）
				var hp: Vector2 = data.get("pos", Vector2.ZERO)
				units.flash_enemy(int(data.get("id", -1)))
				units.play_enemy_hit(int(data.get("id", -1)))
				fx.burst(hp, Color(1.0, 0.93, 0.70), 0.42)
				audio.play("hit")
				hud.add_floater(Vector3(hp.x, 1.9, hp.y), "-%d" % int(float(data.get("dmg", 0))),
					Color(0.98, 0.86, 0.55))
			EventBus.ENEMY_ATTACK:
				# 敌人每次砸墙/拆建筑/打水晶，表现层播一次攻击动作（2026-11-18 步/攻动画接入）
				units.play_enemy_attack(int(data.get("id", -1)))
			EventBus.ENEMY_DIED:
				var dp: Vector2 = data.get("pos", Vector2.ZERO)
				fx.burst(dp, Color(0.95, 0.45, 0.30), 0.85)
				audio.play("kill")
				_hitstop = maxf(_hitstop, 0.05)
			EventBus.PLAYER_HURT:
				var pp: Vector2 = sim.state.player.pos
				hud.add_floater(Vector3(pp.x, 2.3, pp.y), "-%d" % int(float(data.get("dmg", 0))),
					Color(0.98, 0.40, 0.35))
				hud.flash_hurt()
				audio.play("hurt")
			EventBus.WALL_HIT:
				var wp: Vector2 = data.get("pos", Vector2.ZERO)
				hud.add_floater(Vector3(wp.x, 4.2, wp.y), "-%d" % int(float(data.get("dmg", 0))),
					Color(0.95, 0.62, 0.40))
			EventBus.WALL_REPAIRED:
				# 修墙以前完全没有反馈：砖 -1、墙 +900，屏幕上什么都不动（2026-11-09 试玩反馈）
				var rp: Vector2 = data.get("pos", Vector2.ZERO)
				var heal := int(round(float(data.get("heal", 0.0))))
				if heal > 0:
					hud.add_floater(Vector3(rp.x, 4.8, rp.y), "+%d" % heal, Color(0.62, 0.92, 0.66))
					audio.play("repair")
			EventBus.WALL_BREACHED:
				sim.notice("城墙已破 · 退守水晶")
				audio.play("breach")
			EventBus.BUILDING_BUILT:
				audio.play("buy")
				var label := str(data.get("label", ""))
				hud.add_toast("%s 建造完成%s" % [str(data.get("name", "建造物")),
					(" · " + label) if label != "" else ""])
			EventBus.BUILDING_DESTROYED:
				var bp: Vector2 = data.get("pos", Vector2.ZERO)
				fx.burst(bp, Color(0.95, 0.62, 0.35), 0.8)
				audio.play("breach")
				var drops := int(data.get("drops", 0))
				hud.add_toast("%s 被摧毁%s" % [str(data.get("name", "建造物")),
					(" · 掉落 %d 件" % drops) if drops > 0 else ""])
			EventBus.BUILDING_SHOT:
				var from: Vector2 = data.get("from", Vector2.ZERO)
				var to: Vector2 = data.get("to", Vector2.ZERO)
				fx.add_tracer(from, to, Color(1.0, 0.78, 0.40))
				audio.play("shot")
			EventBus.BUILDING_REPAIRED:
				var brp: Vector2 = data.get("pos", Vector2.ZERO)
				var bheal := int(round(float(data.get("heal", 0.0))))
				if bheal > 0:
					hud.add_floater(Vector3(brp.x, 1.9, brp.y), "+%d" % bheal,
						Color(0.62, 0.92, 0.66))
					audio.play("repair")
			EventBus.BUILDING_DEMOLISHED:
				audio.play("buy")
				var refund: Dictionary = data.get("refund", {})
				var parts: PackedStringArray = []
				if int(refund.get("coin", 0)) > 0:
					parts.append("金 %d" % int(refund["coin"]))
				if int(refund.get("brick", 0)) > 0:
					parts.append("砖 %d" % int(refund["brick"]))
				if int(refund.get("metal", 0)) > 0:
					parts.append("金属 %d" % int(refund["metal"]))
				hud.add_toast("拆除 %s%s%s" % [str(data.get("name", "建造物")),
					(" · 返还 " + " ".join(parts)) if not parts.is_empty() else "",
					(" · 箱内 %d 件掉落" % int(data.get("drops", 0)))
						if int(data.get("drops", 0)) > 0 else ""])
			EventBus.DROP_PICKED:
				if str(data.get("kind", "")) == "item":
					hud.add_toast("拾回：%s" % str(data.get("name", "物品")))
				else:
					var dp: Vector2 = data.get("pos", Vector2.ZERO)
					hud.add_floater(Vector3(dp.x, 1.6, dp.y),
						"+%d %s" % [int(data.get("amount", 0)), str(_kind_name(str(data.get("kind", ""))))],
						Color(0.90, 0.86, 0.62))
			EventBus.CRYSTAL_HIT:
				hud.add_floater(Vector3(0, 5.2, 0), "-%d" % int(float(data.get("dmg", 0))),
					Color(0.95, 0.35, 0.35))
				audio.play("crystal")
			EventBus.ITEM_GAINED:
				if bool(data.get("resource", false)):
					hud.add_toast("拾取 %s ×%d" % [str(data.get("name", "资源")),
						int(data.get("amount", 0))])
				else:
					var tier := int(data.get("tier", 0))
					var rarity: Dictionary = sim.cfg.rarity_row(tier)
					hud.add_toast("获得%s：%s（%s）" % [
						str(rarity.get("name", "物品")), str(data.get("name", "")),
						str(data.get("desc", ""))])
			EventBus.LOOT_REVEALED:
				# 扫到一格：空格只给一声轻响，物资给飘字 + 音高更高的确认音
				var rp: Vector2 = data.get("pos", Vector2.ZERO)
				var kind := str(data.get("kind", ""))
				if kind == "":
					audio.play("scan_tick")
				else:
					var tier := clampi(int(data.get("item_tier", 1)), 1, 5)
					var colors := [
						Color(0.82, 0.84, 0.88), Color(0.52, 0.82, 0.56), Color(0.45, 0.72, 0.98),
						Color(0.76, 0.58, 0.98), Color(0.95, 0.78, 0.36),
					]
					# 2026-11-15：扫描只是「发现」，物资还要双击才进背包，
					# 所以不能写 "+N"（那会被读成已入账）
					hud.add_floater(Vector3(rp.x, 2.0, rp.y),
						"发现 %s ×%d" % [str(_kind_name(kind)), int(data.get("amount", 0))],
						colors[tier - 1])
					audio.play("reveal")
			EventBus.PLAYER_BLINK:
				audio.play("roll")
			EventBus.LOOT_OPENED:
				var g: Dictionary = data.get("gain", {})
				var gsum := 0
				for k in g:
					gsum += int(g[k])
				if gsum > 0:
					hud.add_toast(_loot_text(g))
				else:
					hud.add_toast("箱子已搜完 · 双击物资拾取到背包")
				audio.play("loot")
			EventBus.GUARD_DIED:
				hud.add_toast("守卫阵亡")
			EventBus.GUARD_REFILLED:
				hud.add_toast("守卫补充 +%d · 满编 %d" % [int(data.get("refilled", 0)), int(data.get("count", 0))])
			EventBus.PURCHASE:
				var key := str(data.get("key", ""))
				audio.play("buy")
				if key == "wall_upgrade":
					hud.add_toast("城墙第 %d 段 → Lv%d" % [int(data.get("index", 0)) + 1, int(data.get("level", 2))])
				elif key == "wall_rebuild":
					hud.add_toast("城墙第 %d 段已重建" % (int(data.get("index", 0)) + 1))
				elif key == "wall_new":
					hud.add_toast("新建城墙 · 第 %d 段" % (int(data.get("index", 0)) + 1))
				elif key == "weapon_upgrade":
					hud.add_toast("%s → Lv%d" % [
						"锤" if str(data.get("id", "")) == "hammer" else "弩",
						int(data.get("level", 2))])
				elif key == "crystal_upgrade":
					hud.add_toast("水晶升级 → Lv%d" % int(data.get("level", 2)))
				elif key == "refresh":
					hud.add_toast("货架已刷新")
				elif key == "trait_common" or key == "attachment":
					pass          # 物品走 ITEM_GAINED 提示，避免同一件事弹两条
				else:
					# 商店买的砖/金属/弹药/修复包：以前只有数字变化，没有任何确认
					hud.add_toast("已购买 %s" % str(data.get("name", "物品")))
			EventBus.NOTICE:
				sim.notice(str(data.get("text", "")))
			EventBus.PHASE_CHANGED:
				var to_phase := int(data.get("to", -1))
				# 安全阶段立刻落盘：这三个阶段没有敌人，读档不会出现半波次状态
				if to_phase in [GameState.Phase.SCOUT, GameState.Phase.BUILD, GameState.Phase.REWARD]:
					_write_save()
			EventBus.PLAYER_DIED:
				sim.notice("你倒下了 · 复活倒计时 %0.0fs" % float(data.get("timer", 8.0)))
			EventBus.WAVE_STARTED:
				audio.play("wave")
			EventBus.WAVE_CLEARED:
				sim.notice("第 %d 波已守住" % int(data.get("wave", 1)))
			EventBus.RUN_ENDED:
				sim.notice("胜利" if bool(data.get("victory", false)) else "失败")
				_clear_save()          # 通关/团灭后没有可续的局
			_:
				pass


## 光标提示：建造放置 / 拆除 / 墙段升级三套语义共用一条贴光标提示
func _wall_hint() -> String:
	if _build_selected != "":
		if _build_selected == "backpack":
			return "背包扩容 +10 格 · 点击建造卡片立即生效"
		var def := sim.cfg.building_def(_build_selected)
		var check := BuildSystem.can_build(sim.state, sim.cfg, _build_selected, _aim)
		if not bool(check["ok"]):
			return "建造 %s · %s" % [str(def.get("name", "")), str(check["reason"])]
		var cost: Dictionary = check["cost"]
		return "自由建造 %s   %s   [左键] 连续放置 · [V] 退出" % [
			str(def.get("name", "")), _cost_text_of(cost)]
	if _demolish_mode:
		return _demolish_hint()
	if _hover_wall < 0:
		# 没指到墙：建设期提示「在这儿新建一段」，并用与 core 相同的判定说明为什么不能建
		if sim.state.phase != GameState.Phase.BUILD:
			return ""
		var reason := EconomySystem.build_block_reason(sim.state, sim.cfg, _aim)
		if reason != "":
			return "建造 · " + reason
		return "建造城墙段   %d 金 + %d 砖   [E]" % [
			sim.cfg.wall_build_coin_cost(),
			int(sim.cfg.num("wall_rules", "build_brick_cost", 20))]
	if _hover_wall >= sim.state.wall.size():
		return ""
	var seg: GameState.WallSegment = sim.state.wall[_hover_wall]
	if seg.breached:
		return "第 %d 段 · 已破   %d 砖 + %d 金   [E] 重建" % [
			seg.index + 1,
			int(sim.cfg.num("wall_rules", "rebuild_brick_cost", 30)),
			int(sim.cfg.num("wall_rules", "rebuild_coin_cost", 150))]
	if sim.state.phase != GameState.Phase.BUILD:
		return "第 %d 段 · 血量 %d%%（战斗中不能升级）" % [
			seg.index + 1, int(round(seg.hp / maxf(1.0, seg.max_hp) * 100.0))]
	var max_level := int(sim.cfg.num("wall_rules", "max_level", 3))
	if seg.level >= max_level:
		return "第 %d 段 · Lv%d 已满级" % [seg.index + 1, seg.level]
	return "第 %d 段 · Lv%d → Lv%d   %d 砖 + %d 金   [E] 升级" % [
		seg.index + 1, seg.level, seg.level + 1,
		int(sim.cfg.num("wall_rules", "upgrade_brick_cost", 20)),
		int(sim.cfg.num("wall_rules", "upgrade_coin_cost", 80))]


func _demolish_hint() -> String:
	var target: Dictionary = _build_info.get("demolish_target", {})
	if target.is_empty():
		return "拆除模式 · 光标指向建造物或自建城墙"
	if String(target.get("kind", "")) == "building":
		var b := sim.state.building_by_id(int(target.get("id", -1)))
		if b == null:
			return ""
		var name := "木箱" if b.kind == "crate" else "炮台"
		if b.kind == "crate":
			return "拆除 %s · 返还 50%% 建造资源 + 箱内 100%% 掉落" % name
		return "拆除 %s · 返还 50%% 建造资源" % name
	var index := int(target.get("index", -1))
	if index < 0 or index >= sim.state.wall.size():
		return ""
	var seg: GameState.WallSegment = sim.state.wall[index]
	if not seg.built:
		return "初始城墙不可拆除"
	return "拆除 城墙段 · 返还 50%%（约 %d 金 + %d 砖）" % [
		int(round(float(seg.paid_coin) * sim.cfg.build_rule("refund_rate", 0.5))),
		int(round(float(seg.paid_brick) * sim.cfg.build_rule("refund_rate", 0.5)))]


func _cost_text_of(cost: Dictionary) -> String:
	var parts: PackedStringArray = []
	if int(cost.get("coin", 0)) > 0:
		parts.append("%d 金" % int(cost["coin"]))
	if int(cost.get("brick", 0)) > 0:
		parts.append("%d 砖" % int(cost["brick"]))
	if int(cost.get("metal", 0)) > 0:
		parts.append("%d 金属" % int(cost["metal"]))
	if int(cost.get("ammo", 0)) > 0:
		parts.append("%d 弹药" % int(cost["ammo"]))
	return " + ".join(parts) if not parts.is_empty() else "免费"


## 开箱提示里用的中文资源名
func _kind_name(kind: String) -> String:
	match kind:
		"coin": return "金"
		"brick": return "砖"
		"metal": return "金属"
		"ammo": return "弹药"
		_: return kind


## 开箱提示：只列非零收益，避免一行全是 +0
func _loot_text(gain: Dictionary) -> String:
	var parts: PackedStringArray = []
	if int(gain.get("coin", 0)) > 0:
		parts.append("金币 +%d" % int(gain["coin"]))
	if int(gain.get("brick", 0)) > 0:
		parts.append("砖块 +%d" % int(gain["brick"]))
	if int(gain.get("metal", 0)) > 0:
		parts.append("金属 +%d" % int(gain["metal"]))
	if int(gain.get("ammo", 0)) > 0:
		parts.append("弹药 +%d" % int(gain["ammo"]))
	if parts.is_empty():
		return "空箱子"
	return "开箱：" + " · ".join(parts)


func _on_action(action: String) -> void:
	if action == "restart":
		_cancel_build_mode()
		_last_build_id = "crate"
		_close_crate()
		sim.new_run()
		build_layer.reset()
		world.build(sim.cfg, sim.snapshot())
		hud.invalidate()
		_refresh_costs()
		_apply_events(sim.drain_events())
		return
	sim.request(action)


# ------------------------------------------------------------------ 建造 / 拆除 / 木箱仓库

func _on_build_requested(id: String) -> void:
	if sim.state.phase != GameState.Phase.BUILD:
		sim.notice("建设期才能建造")
		return
	# 自由建造模式：同一张卡片不再切换成取消，V / 右键 / Esc 才退出
	# 卡片置灰之外还要挡住快捷键：上限/资源不足时不进入放置模式，直接给原因
	var cap := BuildSystem.cap_reason(sim.state, sim.cfg, id)
	if cap != "":
		sim.notice(cap)
		return
	var cost := BuildSystem.cost_for(sim.state, sim.cfg, id)
	var afford := BuildSystem.afford_reason(sim.state, cost)
	if afford != "":
		sim.notice(afford)
		return
	if _demolish_mode:
		_demolish_mode = false
	# 背包没有地面放置：点一下直接扩容，不打断当前自由建造
	if id == "backpack":
		BuildSystem.build(sim.state, sim.cfg, sim.bus, "backpack")
		build_panel.invalidate()
		return
	_build_selected = id
	_last_build_id = id
	build_panel.invalidate()


func _toggle_free_build() -> void:
	if sim.state.phase != GameState.Phase.BUILD:
		sim.notice("建设期才能自由建造")
		return
	if _build_selected != "":
		_cancel_build_mode()
		sim.notice("已退出自由建造")
		return
	_enter_free_build()


func _enter_free_build() -> void:
	if sim.state.phase != GameState.Phase.BUILD:
		sim.notice("建设期才能自由建造")
		return
	var id := _last_build_id
	if id == "" or id == "backpack":
		id = "crate"
	# 上次选的已到上限就回落到木箱，避免一进模式就是个红 ghost
	if BuildSystem.cap_reason(sim.state, sim.cfg, id) != "":
		id = "crate"
	_demolish_mode = false
	_build_selected = id
	_last_build_id = id
	build_panel.invalidate()
	sim.notice("自由建造：5 木箱 / 6 背包 / 7 城墙 / 8 炮台 · V 退出")


func _on_free_build_toggled(on: bool) -> void:
	if on:
		_enter_free_build()
	else:
		_cancel_build_mode()


func _on_demolish_toggled(on: bool) -> void:
	if sim.state.phase != GameState.Phase.BUILD:
		sim.notice("建设期才能拆除")
		_demolish_mode = false
		build_panel.invalidate()
		return
	_demolish_mode = on
	if on:
		_build_selected = ""
	build_panel.invalidate()


func _place_selected() -> void:
	if _build_selected == "":
		return
	# 自由建造：成功放置后保持当前选中，继续左键可以连续放；
	# 退出走 V / 右键 / Esc，不再「放一个就自动退出」。
	BuildSystem.build(sim.state, sim.cfg, sim.bus, _build_selected, _aim)
	if _build_selected != "":
		_last_build_id = _build_selected


func _demolish_at_aim() -> void:
	BuildSystem.demolish(sim.state, sim.cfg, sim.bus, _aim)


func _cancel_build_mode() -> void:
	_build_selected = ""
	_demolish_mode = false
	if build_layer != null:
		build_layer.set_ghost("", Vector2.ZERO, false)
		build_layer.set_hover(-1)
	if build_panel != null:
		build_panel.invalidate()


func _toggle_crate() -> void:
	if sim.state.phase == GameState.Phase.TITLE or _paused:
		return
	if crate_panel.visible:
		_close_crate()
		return
	if sim.state.near_crate < 0:
		sim.notice("靠近木箱 3m 内才能存取")
		return
	_cancel_build_mode()
	if bag.visible:
		bag.close()
	_close_settings()
	_close_odds()
	crate_panel.open(sim.state.near_crate, sim.snapshot())


func _close_crate() -> void:
	if crate_panel != null and crate_panel.visible:
		crate_panel.close()


func _crate_id() -> int:
	return sim.state.near_crate


func _on_crate_deposit_item(uid: int) -> void:
	BuildSystem.deposit_item(sim.state, sim.cfg, sim.bus, _crate_id(), uid)


func _on_crate_withdraw_slot(slot: int) -> void:
	BuildSystem.withdraw_slot(sim.state, sim.cfg, sim.bus, _crate_id(), slot)


func _on_crate_deposit_resource(kind: String, amount: int) -> void:
	BuildSystem.deposit_resource(sim.state, sim.cfg, sim.bus, _crate_id(), kind, amount)


func _on_crate_withdraw_resource(kind: String, amount: int) -> void:
	BuildSystem.withdraw_resource(sim.state, sim.cfg, sim.bus, _crate_id(), kind, amount)


func _on_crate_deposit_all() -> void:
	for item in sim.state.items.duplicate():
		if not BuildSystem.deposit_item(sim.state, sim.cfg, sim.bus, _crate_id(), item.uid):
			break


func _on_buy(index: int) -> void:
	EconomySystem.buy(sim.state, sim.cfg, sim.bus, index)


func _on_equip_weapon(id: String, slot: int) -> void:
	EconomySystem.equip_owned(sim.state, id, slot, sim.bus)


func _on_refresh() -> void:
	EconomySystem.refresh(sim.state, sim.cfg, sim.bus)


func _on_crystal_upgrade() -> void:
	EconomySystem.upgrade_crystal(sim.state, sim.cfg, sim.bus)
	_refresh_costs()


func _on_weapon_upgrade(id: String) -> void:
	EconomySystem.upgrade_weapon(sim.state, sim.cfg, sim.bus, id)
	_refresh_costs()


## 把「下一级要多少钱」算好交给 HUD：价格在 TSV 里，HUD 不读配置；
## 顺便决定按钮是否置灰（满级 / 资源不够），让「点了没反应」变成「看得见的不可点」
func _refresh_costs() -> void:
	if hud == null:
		return
	var costs := {}
	for id in ["crossbow", "hammer"]:
		var lv := int(sim.state.player.weapon_levels.get(id, 1))
		var row := sim.cfg.weapon_level_row(id, lv + 1)
		var maxed := int(row.get("level", 0)) <= lv
		costs[id] = {
			"coin": 0 if maxed else int(row.get("cost_coin", 0)),
			"metal": 0 if maxed else int(row.get("cost_metal", 0)),
			"max": maxed,
		}
	var crystal_lv := int(sim.state.crystal_level)
	var next_crystal := sim.cfg.crystal_row(crystal_lv + 1)
	var crystal_maxed := crystal_lv >= 10
	costs["crystal"] = {
		"coin": 0 if crystal_maxed else int(next_crystal.get("cost_coin", 0)),
		"metal": 0 if crystal_maxed else int(next_crystal.get("cost_metal", 0)),
		"max": crystal_maxed,
	}
	hud.set_upgrade_costs(costs)


func _on_equip(uid: int) -> void:
	if not InventorySystem.equip(sim.state, sim.cfg, uid):
		sim.notice("装备位已满或已装备")
		hud.add_toast("装备失败：装备位已满")


func _on_unequip(uid: int) -> void:
	InventorySystem.unequip(sim.state, uid)


func _on_sell(uid: int) -> void:
	var price := InventorySystem.sell(sim.state, uid)
	if price > 0:
		hud.add_toast("卖出：金币 +%d" % price)


func _on_pick(index: int) -> void:
	RewardSystem.choose(sim.state, sim.cfg, sim.bus, index)
