class_name Hud
extends Control
## 界面层 · HUD：只读 snapshot()，所有操作通过信号回到 app 层。
## 保留的核心体验：顶部信息条（水晶/城墙/波次）+ 底部装备栏（血/弹药/槽位）+ 光标准星。

signal request_action(action: String)
signal request_bag
signal request_buy(index: int)
signal request_refresh
signal request_crystal_upgrade
signal request_weapon_upgrade(id: String)
signal request_equip_weapon(id: String, slot: int)
signal request_pick(index: int)
signal request_equip(uid: int)
signal request_unequip(uid: int)
signal request_sell(uid: int)

const COL_BG := Color(0.06, 0.07, 0.09, 0.92)
const COL_LINE := Color(1, 1, 1, 0.16)
const COL_TEXT := Color(0.92, 0.94, 0.97)
const COL_DIM := Color(0.62, 0.66, 0.72)
const COL_HP := Color(0.55, 0.82, 0.55)
const COL_WARN := Color(0.92, 0.55, 0.35)
const COL_CRYSTAL := Color(0.40, 0.78, 0.96)
const COL_GOLD := Color(0.95, 0.80, 0.42)

var snap: Dictionary = {}
var notice := ""
var _font: Font
var _skin: HudSkin = HudSkin.new()
var _panel_box: VBoxContainer
var _panel_scroll: ScrollContainer
var _panel_bg: Panel
var _reward_wrap: VBoxContainer
var _reward_row: HBoxContainer
var _reward_title: Label
var _reward_mode := false
var _panel_key := ""
var _mouse := Vector2.ZERO
var focus_aim := false
var wall_hint := ""            # 建设期悬停墙段的升级提示（空串 = 不显示）
var _floaters: Array = []      # 飘字：{pos: Vector3, text, color, t}
var _toasts: Array = []        # 提示条：{text, t}
var _clicks: Array = []        # 点击涟漪：{pos, t}（P1-2 之后补的通用点击反馈）
var _hurt_flash := 0.0         # 玩家受击的整屏红闪（P0-3），秒
var upgrade_costs := {}        # app 注入的升级价目：{crossbow/hammer/crystal: {coin, metal}}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_viewport().size_changed.connect(_sync_size)
	_sync_size()
	_font = ThemeDB.fallback_font
	# 皮肤化按钮三态：挂在 Hud 上，面板里的按钮子树自动继承
	theme = _skin.build_theme()
	# 面板底单独用一个 Panel 垫在 VBox 下方，避免改动既有锚点布局
	_panel_bg = Panel.new()
	_panel_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_bg.visible = false
	var panel_sb := _skin.panel_style()
	if panel_sb != null:
		_panel_bg.add_theme_stylebox_override("panel", panel_sb)
	add_child(_panel_bg)
	_panel_scroll = ScrollContainer.new()
	_panel_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_panel_scroll)
	_panel_box = VBoxContainer.new()
	_panel_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_box.add_theme_constant_override("separation", 5)
	_panel_scroll.add_child(_panel_box)
	_panel_box.minimum_size_changed.connect(_sync_panel_bg)

	# 波末奖励：三张竖卡横排（reward_card 的正确用法，不塞进右侧面板）
	_reward_wrap = VBoxContainer.new()
	_reward_wrap.add_theme_constant_override("separation", 10)
	_reward_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reward_wrap.visible = false
	add_child(_reward_wrap)
	_reward_title = Label.new()
	_reward_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_reward_title.add_theme_font_size_override("font_size", 18)
	_reward_title.add_theme_color_override("font_color", COL_GOLD)
	_reward_wrap.add_child(_reward_title)
	_reward_row = HBoxContainer.new()
	_reward_row.add_theme_constant_override("separation", 16)
	_reward_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_reward_wrap.add_child(_reward_row)


## 面板底跟随 VBox 的包围盒（容器布局变化不是信号事件，跟随是最省的做法）
func _sync_panel_bg() -> void:
	if _panel_bg == null or _panel_box == null:
		return
	var empty := _panel_box.get_child_count() == 0
	_panel_scroll.visible = not empty and not _reward_mode
	_panel_bg.visible = _panel_scroll.visible
	if not _panel_scroll.visible:
		return
	var pad := Vector2(12, 10)
	var width := minf(304.0, size.x - 2.0 * pad.x)
	var height := minf(_panel_box.get_combined_minimum_size().y, maxf(48.0, size.y - 180.0))
	_panel_scroll.position = Vector2(size.x - width - 18.0, 78.0)
	_panel_scroll.size = Vector2(width, height)
	_panel_bg.position = _panel_scroll.position - pad
	_panel_bg.size = _panel_scroll.size + pad * 2.0


## CanvasLayer 下的锚点不会自动铺满视口，手动同步一次
func blocks_shop_click(point: Vector2) -> bool:
	return _panel_bg != null and _panel_bg.visible and _panel_bg.get_global_rect().has_point(point)


func _sync_size() -> void:
	position = Vector2.ZERO
	size = get_viewport_rect().size
	_sync_panel_bg()
	if _reward_wrap != null:
		_place_reward_wrap()


func update_snapshot(s: Dictionary) -> void:
	snap = s
	_mouse = get_viewport().get_mouse_position()
	_sync_panels()
	queue_redraw()


## 精确瞄准状态由 app 层注入（只影响绘制，不影响判定）
func set_focus_aim(on: bool) -> void:
	focus_aim = on
	queue_redraw()


## 建设期悬停墙段的升级提示（P0-7）。文案由 app 层生成（要读 cfg 的价格与等级上限），
## HUD 只负责贴光标画出来——面板已经塞满 11 个按钮，放不下了。
func set_wall_hint(text: String) -> void:
	if text == wall_hint:
		return
	wall_hint = text
	queue_redraw()


## 世界坐标飘字（墙段/水晶受击）
func add_floater(world_pos: Vector3, text: String, color: Color = Color(0.95, 0.55, 0.45)) -> void:
	_floaters.append({"pos": world_pos, "text": text, "color": color, "t": 0.9})
	if _floaters.size() > 24:
		_floaters.pop_front()


## 顶部提示条（开箱、守卫补充等）
func add_toast(text: String) -> void:
	_toasts.append({"text": text, "t": 2.4})
	if _toasts.size() > 3:
		_toasts.pop_front()


## 玩家受击：整屏红闪。0.32s 线性淡出，比飘字更容易被余光捕捉到。
func flash_hurt(strength: float = 1.0) -> void:
	_hurt_flash = maxf(_hurt_flash, 0.32 * clampf(strength, 0.3, 1.0))


## 点击反馈：在点击位置画一圈扩散的环。按钮有没有生效看不出来时，这是唯一的「我点到了」证据。
func pulse_click(pos: Vector2) -> void:
	_clicks.append({"pos": pos, "t": 0.22})
	if _clicks.size() > 8:
		_clicks.pop_front()


## app 注入升级价目（价格在 TSV/JSON 里，HUD 不读配置，只拿算好的结果）
func set_upgrade_costs(data: Dictionary) -> void:
	upgrade_costs = data
	invalidate()


## 外部强制重建面板（重开局时调用）
func invalidate() -> void:
	_panel_key = ""


func _process(dt: float) -> void:
	if snap.is_empty():
		return
	_mouse = get_viewport().get_mouse_position()
	for f in _floaters:
		f["t"] = float(f["t"]) - dt
	_floaters = _floaters.filter(func(f): return float(f["t"]) > 0.0)
	for t in _toasts:
		t["t"] = float(t["t"]) - dt
	_toasts = _toasts.filter(func(t): return float(t["t"]) > 0.0)
	for c in _clicks:
		c["t"] = float(c["t"]) - dt
	_clicks = _clicks.filter(func(c): return float(c["t"]) > 0.0)
	_hurt_flash = maxf(0.0, _hurt_flash - dt)
	queue_redraw()


# ------------------------------------------------------------------ 绘制

func _draw() -> void:
	if snap.is_empty():
		return
	var vp := size
	# 受击红闪垫在最底层：HUD 文字与图标必须仍然读得清
	if _hurt_flash > 0.0:
		draw_rect(Rect2(Vector2.ZERO, vp), Color(0.72, 0.06, 0.05, 0.34 * (_hurt_flash / 0.32)))
	var wall := _wall_state()
	if int(wall["breached"]) > 0:
		var marks: Array[Vector2] = wall["marks"]
		var pulse := 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) / 1000.0 * 7.0)
		_skin.draw_danger(self, vp, marks, pulse)
	_draw_top_bar(vp, wall)
	_draw_resources(vp)
	_draw_bottom_bar(vp)
	_draw_center_messages(vp)
	_draw_storage_hint(vp)
	_draw_crosshair()
	_draw_click_pulses()
	_draw_wall_hint()
	_draw_wall_health()
	_draw_building_health()
	_draw_offscreen_enemies(vp)
	_draw_floaters()
	_draw_toasts(vp)


## 汇总城墙状态：总血量比、破口数、破口段的屏幕坐标（供三角标定位）。
func _wall_state() -> Dictionary:
	var total := 0.0
	var total_max := 0.0
	var breached := 0
	var marks: Array[Vector2] = []
	var cam := get_viewport().get_camera_3d()
	for seg in snap["wall"]:
		total += float(seg["hp"])
		total_max += float(seg["max_hp"])
		if not bool(seg["breached"]):
			continue
		breached += 1
		if cam == null:
			continue
		var c: Vector2 = seg["center"]
		var world := Vector3(c.x, 4.6, c.y)
		if not cam.is_position_behind(world):
			# 三角标放在墙格上方，避免与破口格贴图重叠
			marks.append(cam.unproject_position(world) - Vector2(0, 26))
	return {"ratio": total / maxf(1.0, total_max), "breached": breached, "marks": marks}


func _draw_top_bar(vp: Vector2, wall: Dictionary) -> void:
	draw_rect(Rect2(0, 0, vp.x, 54), COL_BG)
	draw_line(Vector2(0, 54), Vector2(vp.x, 54), COL_LINE, 1.0)

	var wave_txt := "第 %d / 5 波" % int(snap["wave_index"])
	var phase_txt := str(snap["phase_name"])
	_text(Vector2(18, 24), wave_txt, 20, COL_TEXT)
	_text(Vector2(18, 44), phase_txt, 13, COL_DIM)

	var c: Dictionary = snap["crystal"]
	var ratio := float(c["hp"]) / maxf(1.0, float(c["max_hp"]))
	_skin.draw_bar(self, Rect2(vp.x * 0.5 - 190, 14, 380, 16), ratio, COL_CRYSTAL)
	_text(Vector2(vp.x * 0.5 - 186, 46), "水晶 %d / %d · Lv%d" % [int(c["hp"]), int(c["max_hp"]), int(c["level"])], 12, COL_DIM)

	# 城墙：7 格刻度条承担主读数，数字降为下方一行注释
	var breached := int(wall["breached"])
	var gauge_x := vp.x - 386.0
	_skin.draw_gauge(self, Rect2(gauge_x, 5, 360, 32), float(wall["ratio"]))
	_text(Vector2(gauge_x, 51), "城墙 %.1f%% · 破口 %d · 守卫 %d / %d" % [
		float(wall["ratio"]) * 100.0, breached,
		int(snap["guards_alive"]), int(snap["guard_capacity"])],
		12, COL_WARN if breached > 0 else COL_DIM)

	if float(snap["phase_duration"]) > 0.0:
		var left := maxf(0.0, float(snap["phase_duration"]) - float(snap["phase_time"]))
		_text(Vector2(vp.x * 0.5 - 40, 44), "%0.0fs" % left, 12, COL_DIM)


func _draw_resources(vp: Vector2) -> void:
	var y := 84.0
	var items: Array = [
		["icon_coin", int(snap["coin"]), COL_GOLD],
		["icon_brick", int(snap["brick"]), Color(0.78, 0.62, 0.44)],
		["icon_metal", int(snap["metal"]), Color(0.72, 0.78, 0.86)],
		["icon_ammo", int(snap["ammo"]), Color(0.95, 0.72, 0.50)],
	]
	for it in items:
		_skin.draw_icon(self, str(it[0]), Rect2(18, y - 16, 20, 20))
		_text(Vector2(44, y), "%d" % int(it[1]), 15, it[2])
		y += 24.0


func _draw_bottom_bar(vp: Vector2) -> void:
	var h := 90.0
	var r := Rect2(0, vp.y - h, vp.x, h)
	draw_rect(r, COL_BG)
	draw_line(Vector2(0, vp.y - h), Vector2(vp.x, vp.y - h), COL_LINE, 1.0)

	var p: Dictionary = snap["player"]
	var hp_ratio := float(p["hp"]) / maxf(1.0, float(p["max_hp"]))
	_bar(Rect2(20, vp.y - 66, 240, 18), hp_ratio, COL_HP if hp_ratio > 0.35 else COL_WARN)
	_text(Vector2(20, vp.y - 72), "生命 %d / %d" % [int(p["hp"]), int(p["max_hp"])], 13, COL_DIM)

	var slots: Array = p["slots"]
	var levels: Dictionary = p["weapon_levels"]
	var active := int(p["active_slot"])
	var labels := [
		"1  %s" % _weapon_label(str(slots[0]), levels),
		"2  %s" % _weapon_label(str(slots[1]), levels),
		"3  锤",
		"4  刀",
	]
	var icon_keys := ["icon_crossbow", "icon_crossbow", "icon_hammer", "icon_knife"]
	for i in range(labels.size()):
		var x := 290.0 + i * 150.0
		var box := Rect2(x, vp.y - 74, 52, 52)
		_skin.draw_slot(self, box, i == active)
		# 空槽不画武器图标：槽位 1/2 未装备时 slots[i] 为空串
		var slotted := i >= 2 or str(slots[i]) != ""
		if slotted:
			_skin.draw_icon(self, str(icon_keys[i]), Rect2(box.position + Vector2(8, 8), Vector2(36, 36)))
		_text(Vector2(x + 60, vp.y - 40), labels[i], 13, COL_TEXT)

	# 翻滚冷却（右键）：槽位右侧一条细读数，建设中/战斗中都能看到
	var roll_cd := float(p.get("roll_cd", 0.0))
	var roll_max := maxf(0.01, float(p.get("roll_cooldown", 0.9)))
	var rolling := bool(p.get("rolling", false))
	var rx := 290.0 + 4.0 * 150.0
	var ready := roll_cd <= 0.001
	var roll_col := COL_GOLD if ready or rolling else COL_DIM
	_text(Vector2(rx, vp.y - 48), "翻滚" if not rolling else "翻滚中", 12, roll_col)
	_text(Vector2(rx, vp.y - 32), "就绪" if ready else "%0.1fs" % roll_cd, 12, roll_col)
	var rrect := Rect2(rx + 44, vp.y - 44, 96, 4)
	draw_rect(rrect, Color(1, 1, 1, 0.12))
	draw_rect(Rect2(rrect.position, Vector2(rrect.size.x * (1.0 - roll_cd / roll_max), rrect.size.y)), roll_col)

	if not bool(p["alive"]):
		_text(Vector2(vp.x * 0.5 - 150, vp.y - 110), "倒地 · %0.1fs 后在水晶复活" % float(p["respawn_timer"]), 20, COL_WARN)


func _draw_center_messages(vp: Vector2) -> void:
	var label := str(snap["notice"])
	if float(snap["notice_timer"]) > 0.0 and label != "":
		# 加一条底带：纯文字在杂乱场景里会被读丢，「买了没反应」有一半是没看见这句话
		var w := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		var alpha := clampf(float(snap["notice_timer"]) / 0.5, 0.0, 1.0)
		_skin.draw_notice(self, Rect2(vp.x * 0.5 - w * 0.5 - 20, vp.y - 172, w + 40, 30), alpha)
		_text(Vector2(vp.x * 0.5 - w * 0.5, vp.y - 150), label, 16, COL_GOLD)

	match int(snap["phase"]):
		GameState.Phase.DEFEAT:
			_text_center(vp, "水 晶 已 碎", 44, Color(0.92, 0.45, 0.40), -60)
			_text_center(vp, "第 %d 波失守 · 击杀 %d" % [int(snap["wave_index"]), int(snap["stats"]["kills"])], 16, COL_DIM, -14)
			_text_center(vp, "点击「重新开始」", 15, COL_GOLD, 20)
		GameState.Phase.VICTORY:
			_text_center(vp, "守 住 了", 44, COL_CRYSTAL, -60)
			_text_center(vp, "5 波全清 · 击杀 %d · 死亡 %d 次" % [int(snap["stats"]["kills"]), int(snap["stats"]["deaths"])], 16, COL_DIM, -14)
			_text_center(vp, "点击「再来一局」", 15, COL_GOLD, 20)


## 靠近木箱（3m）时的存取提示：R 开仓库
func _draw_storage_hint(vp: Vector2) -> void:
	var crate_id := int(snap.get("near_crate", -1))
	if crate_id < 0:
		return
	if int(snap["phase"]) not in [GameState.Phase.SCOUT, GameState.Phase.BUILD, GameState.Phase.WAVE]:
		return
	var crate := {}
	for b in snap.get("buildings", []):
		if int(b.get("id", -1)) == crate_id:
			crate = b
			break
	if crate.is_empty():
		return
	var label := "R 存取木箱 #%d · %d / %d 格" % [
		int(crate.get("index", 1)), int(crate.get("stored_used", 0)),
		int(crate.get("stored_total", 25))]
	var w := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	var y := vp.y - 112.0
	_skin.draw_notice(self, Rect2(vp.x * 0.5 - w * 0.5 - 16, y - 17, w + 32, 26), 1.0)
	_text(Vector2(vp.x * 0.5 - w * 0.5, y), label, 13, COL_GOLD)


func _draw_crosshair() -> void:
	if int(snap["phase"]) in [GameState.Phase.TITLE, GameState.Phase.DEFEAT, GameState.Phase.VICTORY]:
		return
	_skin.draw_crosshair(self, _mouse, focus_aim)


## 点击涟漪：0.22s 内从 8px 扩到 24px 并淡出
func _draw_click_pulses() -> void:
	for c in _clicks:
		var k := clampf(float(c["t"]) / 0.22, 0.0, 1.0)
		var p: Vector2 = c["pos"]
		draw_arc(p, 8.0 + (1.0 - k) * 16.0, 0.0, TAU, 28,
			Color(0.96, 0.87, 0.56, 0.6 * k), 2.0)


## 墙段升级提示：贴着光标右上角画，避免玩家去右侧面板里找
func _draw_wall_hint() -> void:
	if wall_hint == "":
		return
	var pos := _mouse + Vector2(24, -30)
	var w := _font.get_string_size(wall_hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_rect(Rect2(pos + Vector2(-9, -17), Vector2(w + 18, 25)), Color(0.05, 0.06, 0.08, 0.88))
	_text(pos, wall_hint, 13, COL_GOLD)


## 木箱/炮台的耐久：受伤后显示一条 40×4 的小血条，满血不画，避免场景里到处是条
func _draw_building_health() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var player_pos: Vector2 = snap["player"]["pos"]
	for b in snap.get("buildings", []):
		var ratio := float(b.get("hp", 1.0)) / maxf(1.0, float(b.get("max_hp", 1.0)))
		var pos: Vector2 = b.get("pos", Vector2.ZERO)
		if ratio >= 0.999 and pos.distance_to(player_pos) > 6.0:
			continue
		var world := Vector3(pos.x, 1.9 if str(b.get("kind", "")) == "crate" else 2.1, pos.y)
		if cam.is_position_behind(world):
			continue
		var sp: Vector2 = cam.unproject_position(world)
		if sp.y < 58.0 or sp.y > size.y - 96.0:
			continue
		var rect := Rect2(sp - Vector2(20, 0), Vector2(40, 4))
		draw_rect(rect, Color(0, 0, 0, 0.55))
		var fill := Color(0.55, 0.82, 0.55).lerp(Color(0.92, 0.45, 0.30), 1.0 - ratio)
		draw_rect(Rect2(rect.position, Vector2(rect.size.x * clampf(ratio, 0.0, 1.0), rect.size.y)), fill)
		draw_rect(rect, Color(1, 1, 1, 0.20), false, 1.0)


## 屏外敌人指示：投影到屏幕外时，在边缘画方向箭头（§15.3 可读性）
func _draw_offscreen_enemies(vp: Vector2) -> void:
	if int(snap["phase"]) not in [GameState.Phase.SCOUT, GameState.Phase.WAVE]:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var rect := Rect2(Vector2.ZERO, vp).grow(-30.0)
	var center := vp * 0.5
	var half := vp * 0.5 - Vector2(44.0, 44.0)
	for e in snap["enemies"]:
		var pos: Vector2 = e["pos"]
		var world := Vector3(pos.x, 1.2, pos.y)
		var sp := cam.unproject_position(world)
		var behind := cam.is_position_behind(world)
		if not behind and rect.has_point(sp):
			continue
		var dir := (sp - center) if not behind else (center - sp)
		if dir.length() < 1.0:
			dir = Vector2(0, -1)
		dir = dir.normalized()
		var scale := minf(half.x / maxf(0.001, absf(dir.x)), half.y / maxf(0.001, absf(dir.y)))
		var tip := center + dir * scale
		var side := Vector2(-dir.y, dir.x)
		var base := tip - dir * 13.0
		var far := clampf(pos.distance_to(snap["player"]["pos"]) / 45.0, 0.25, 1.0)
		draw_colored_polygon(PackedVector2Array([tip, base + side * 6.5, base - side * 6.5]),
			Color(0.95, 0.35, 0.30, 0.35 + 0.5 * far))


## 受击飘字：跟随世界坐标向上飘并淡出，解决"看不到掉血"的感知问题
func _draw_floaters() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	for f in _floaters:
		var age := 0.9 - float(f["t"])
		var world: Vector3 = f["pos"] + Vector3(0, age * 1.6, 0)
		if cam.is_position_behind(world):
			continue
		var sp := cam.unproject_position(world)
		var c: Color = f["color"]
		c.a = clampf(float(f["t"]) / 0.9, 0.0, 1.0)
		_text(sp + Vector2(-12, 0), String(f["text"]), 15, c)


## 顶部提示条：新消息从下往上堆叠，底图用 notice_ribbon 九宫格
func _draw_toasts(vp: Vector2) -> void:
	var y := 96.0
	for t in _toasts:
		var c := COL_TEXT
		c.a = clampf(float(t["t"]) / 0.6, 0.0, 1.0)
		var label := String(t["text"])
		var w := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
		_skin.draw_notice(self, Rect2(vp.x * 0.5 - w * 0.5 - 18, y - 21, w + 36, 30), c.a)
		_text(Vector2(vp.x * 0.5 - w * 0.5, y), label, 15, c)
		y += 34.0


## 墙段状态：每段用一个 48×36 的三态格子（完好/受损/破口）代替原来的 5px 细血条
func _draw_wall_health() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	for seg in snap["wall"]:
		var center: Vector2 = seg["center"]
		var world := Vector3(center.x, 4.6, center.y)
		if cam.is_position_behind(world):
			continue
		var sp := cam.unproject_position(world)
		# 裁掉顶栏与底栏区域，避免世界标记压在 HUD 上
		if sp.y < 58.0 or sp.y > size.y - 96.0:
			continue
		var ratio := float(seg["hp"]) / maxf(1.0, float(seg["max_hp"]))
		var state := 2 if bool(seg["breached"]) else (0 if ratio > 0.6 else 1)
		_skin.draw_wall_cell(self, sp, state)


# ------------------------------------------------------------------ 面板

func _sync_panels() -> void:
	var key := _panel_signature()
	if key == _panel_key:
		return
	_panel_key = key
	for c in _panel_box.get_children():
		_panel_box.remove_child(c)
		c.queue_free()

	# 奖励阶段改用三列卡片，右侧竖列面板退场
	var reward_phase := int(snap["phase"]) == GameState.Phase.REWARD
	if reward_phase != _reward_mode:
		_reward_mode = reward_phase
		_panel_box.visible = not reward_phase
		_reward_wrap.visible = reward_phase
		_sync_panel_bg()

	match int(snap["phase"]):
		GameState.Phase.BUILD:
			_add_label("建设期 · 商店（B 背包）")
			var stock: Array = snap["shop_stock"]
			var weapon_rows := 0
			for shop_row in stock:
				if str(shop_row.get("action", "")) == "weapon":
					weapon_rows += 1
			var compact_shop := weapon_rows > 2
			_panel_box.add_theme_constant_override("separation", 2 if compact_shop else 5)
			for i in range(stock.size()):
				var slot: Dictionary = stock[i]
				var owned: Array = snap["player"].get("owned_weapons", [])
				var is_weapon := str(slot.get("action", "")) == "weapon"
				var text: String = "%s  %d金" % [slot["name"], int(slot["price_coin"])]
				if int(slot.get("price_metal", 0)) > 0:
					text += " %d金属" % int(slot["price_metal"])
				var usable := true
				if bool(slot["locked"]):
					text += "  · 第%d波解锁" % int(slot.get("unlock_wave", int(snap.get("wave_index", 1)) + 1))
					usable = false
				elif owned.has(str(slot["key"])):
					text += "  · 已拥有"
					usable = false
				elif int(slot["sold"]) >= int(slot["limit"]):
					text += "  · 售罄"
					usable = false
				elif int(snap["coin"]) < int(slot["price_coin"]) or int(snap["metal"]) < int(slot["price_metal"]):
					text += "  · 资源不足"
					usable = false
				var idx := i
				_add_button(text, func(): request_buy.emit(idx), 24 if compact_shop else (27 if is_weapon else 30), usable)
			if not stock.is_empty():
				var owned_ids: Array = snap["player"].get("owned_weapons", [])
				if not owned_ids.is_empty():
					_add_label("装备武器 · 选择槽位内容")
					for target_slot in range(2):
						var selector := OptionButton.new()
						selector.custom_minimum_size = Vector2(280, 28)
						selector.add_theme_font_size_override("font_size", 12)
						var current_weapon := str(snap["player"]["slots"][target_slot])
						var selected_index := owned_ids.find(current_weapon)
						if current_weapon.is_empty():
							selector.add_item("槽%d  ·  空" % (target_slot + 1))
						for weapon_index in range(owned_ids.size()):
							var id := str(owned_ids[weapon_index])
							selector.add_item("槽%d  ·  %s" % [target_slot + 1, _weapon_label(id, snap["player"].get("weapon_levels", {}))])
						selector.select(maxi(0, selected_index) if not current_weapon.is_empty() else 0)
						var slot_copy := target_slot
						var offset := 0 if not current_weapon.is_empty() else 1
						selector.item_selected.connect(func(index: int):
							if index >= offset:
								request_equip_weapon.emit(str(owned_ids[index - offset]), slot_copy))
						_panel_box.add_child(selector)
			_add_button("刷新轮换格（40 金）", func(): request_refresh.emit(), 28,
				int(snap["coin"]) >= 40)
			_add_button(_upgrade_label("水晶升级", "crystal", int(snap["crystal"]["level"])),
				func(): request_crystal_upgrade.emit(), 30, _can_afford("crystal"))
			_add_button(_upgrade_label("强化弩", "crossbow", int(snap["player"]["weapon_levels"].get("crossbow", 1))),
				func(): request_weapon_upgrade.emit("crossbow"), 30, _can_afford("crossbow"))
			_add_button(_upgrade_label("强化锤", "hammer", int(snap["player"]["weapon_levels"].get("hammer", 1))),
				func(): request_weapon_upgrade.emit("hammer"), 30, _can_afford("hammer"))
			_add_button("背包（B）", func(): request_bag.emit(), 30)
			_add_button("开始本波（F）", func(): request_action.emit("start_wave"), 30)
		GameState.Phase.SCOUT:
			_add_label("搜集期 · 靠近箱子开始搜索")
			_add_button("提前回城（F）", func(): request_action.emit("return_city"))
		GameState.Phase.REWARD:
			_build_reward_cards()
		GameState.Phase.DEFEAT, GameState.Phase.VICTORY:
			_add_button("重新开始", func(): request_action.emit("restart"))

	# 面板底只在竖列面板上用；奖励阶段由卡片自己撑背景
	_sync_panel_bg()


## 波末奖励：三张 220×300 竖卡横排。卡面用 reward_card 原尺寸，
## 不给它加任何缩放——四角铆钉一拉伸就会糊。
func _build_reward_cards() -> void:
	for c in _reward_row.get_children():
		# 先摘出树再 queue_free：否则被删的卡片还挂在树上，宽度算多一张、居中会偏
		_reward_row.remove_child(c)
		c.queue_free()
	var choices: Array = snap["reward_choices"]
	_reward_title.text = "波末奖励 · 三选一" if choices.size() == 3 else "本局主题 · 四选一"
	var card_sb := _skin.card_style()
	for i in range(choices.size()):
		var ch: Dictionary = choices[i]
		var idx := i
		var b := Button.new()
		b.text = "%s\n\n%s" % [ch["name"], ch["desc"]]
		b.custom_minimum_size = Vector2(220, 300)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.add_theme_font_size_override("font_size", 15)
		b.add_theme_color_override("font_color", Color(0.90, 0.92, 0.95))
		b.add_theme_color_override("font_hover_color", Color(1.0, 0.97, 0.90))
		if card_sb != null:
			for st in ["normal", "hover", "pressed"]:
				b.add_theme_stylebox_override(st, card_sb)
			b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.pressed.connect(func(): request_pick.emit(idx))
		_reward_row.add_child(b)
	_place_reward_wrap()


## 卡片组水平居中、垂直略高于画面中心（下方留出提示文字的余量）
func _place_reward_wrap() -> void:
	if _reward_wrap == null or _reward_row == null:
		return
	var n := _reward_row.get_child_count()
	var w := 220.0 * n + 16.0 * maxf(0.0, float(n) - 1.0)
	_reward_wrap.position = Vector2((size.x - w) * 0.5, maxf(120.0, size.y * 0.5 - 190.0))


func _panel_signature() -> String:
	return "%d|%d|%d|%d|%d|%d|%d|%d|%d" % [
		int(snap["phase"]), int(snap["coin"]), int(snap["brick"]), int(snap["metal"]),
		int(snap["crystal"]["level"]), int(snap["player"]["weapon_levels"].get("crossbow", 1)),
		int(snap["player"]["weapon_levels"].get("hammer", 1)),
		snap["shop_stock"].size(), snap["reward_choices"].size(),
	] + "|%d|%s|%s" % [snap["items"].size(), str(snap["player"].get("owned_weapons", [])), str(snap["player"].get("slots", []))]


## 背包面板：每件物品一行 = [装备/卸下] + [卖出]
func _add_button(text: String, cb: Callable, height: int = 38, enabled: bool = true) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(300, height)
	b.add_theme_font_size_override("font_size", 12 if height <= 24 else 13)
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.disabled = not enabled
	b.pressed.connect(cb)
	_panel_box.add_child(b)


## 价目后缀：按钮上直接写清要花多少，点不动时玩家不用猜为什么
func _cost_text(key: String) -> String:
	var c: Dictionary = upgrade_costs.get(key, {})
	if c.is_empty():
		return ""
	var parts: PackedStringArray = []
	if int(c.get("coin", 0)) > 0:
		parts.append("%d金" % int(c["coin"]))
	if int(c.get("metal", 0)) > 0:
		parts.append("%d金属" % int(c["metal"]))
	return "" if parts.is_empty() else "  ·  " + " ".join(parts)


func _is_max(key: String) -> bool:
	return bool(upgrade_costs.get(key, {}).get("max", false))


## 统一生成升级按钮文案：满级 / 未满级两种，避免三个按钮各写一遍格式串
func _upgrade_label(base: String, key: String, level: int) -> String:
	if _is_max(key):
		return "%s（Lv%d · 已满级）" % [base, level]
	return "%s（Lv%d → %d）%s" % [base, level, level + 1, _cost_text(key)]


func _can_afford(key: String) -> bool:
	var c: Dictionary = upgrade_costs.get(key, {})
	if c.is_empty() or bool(c.get("max", false)):
		return not bool(c.get("max", false))
	return int(snap["coin"]) >= int(c.get("coin", 0)) and int(snap["metal"]) >= int(c.get("metal", 0))


func _add_label(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", COL_DIM)
	_panel_box.add_child(l)


# ------------------------------------------------------------------ 工具

const WEAPON_NAMES := {"crossbow": "弩", "light_crossbow": "轻弩", "longsword": "长剑", "rifle": "步枪", "pistol": "手枪", "rpg": "火箭筒", "knife": "刀", "hammer": "锤"}


func _weapon_label(id: String, levels: Dictionary) -> String:
	if id == "":
		return "空槽"
	return "%s Lv%d" % [WEAPON_NAMES.get(id, id), int(levels.get(id, 1))]


func _text(pos: Vector2, text: String, size_px: int, color: Color) -> void:
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px, color)


func _text_center(vp: Vector2, text: String, size_px: int, color: Color, dy: float) -> void:
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x
	draw_string(_font, Vector2(vp.x * 0.5 - w * 0.5, vp.y * 0.5 + dy), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size_px, color)


## 主血条：交给皮肤层用 bar_bg/fill/frame 三件套绘制
func _bar(rect: Rect2, ratio: float, color: Color) -> void:
	_skin.draw_bar(self, rect, ratio, color)