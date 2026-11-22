class_name MainMenu
extends Control
## 主菜单（2026-11-08 新增）：标题 / 开始 / 玩法说明 / 退出。
## 只发信号，不碰 Sim；由 GameApp 决定显示时机与信号接线。
## 视觉沿用 HudSkin（面板底 + 按钮三态），不新增纹理依赖。

signal start_requested
signal continue_requested
signal settings_requested
signal odds_requested
signal quit_requested

const COL_TEXT := Color(0.92, 0.94, 0.97)
const COL_DIM := Color(0.62, 0.66, 0.72)
const COL_GOLD := Color(0.95, 0.80, 0.42)
const COL_BG := Color(0.05, 0.06, 0.08, 0.96)
const BTN_SIZE := Vector2(340, 54)
const BTN_GAP := 56.0
const HELP_SIZE := Vector2(760, 452)

var _skin := HudSkin.new()
var _title: Label
var _subtitle: Label
var _footer: Label
var _hint: Label
var _buttons: Array = []
var _continue_btn: Button
## 上层有全屏覆盖层（设置/概率公示）时由 app 关掉，避免 F / Enter 穿透到「开始游戏」
var input_enabled := true
var _help: Control
var _help_panel: Panel
var _help_title: Label
var _help_body: Label
var _help_close: Button


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = _skin.build_theme()
	_build()
	_sync_size()
	get_viewport().size_changed.connect(_sync_size)


func _build() -> void:
	_title = _label("城  墙  尸  潮", 64, COL_TEXT)
	_subtitle = _label("2.5D 守城 · 搜集 / 建设 / 守波 / 奖励", 18, COL_DIM)

	# 继续只在有存档时出现；没有存档时按钮不占位（布局跳过 hidden）
	_continue_btn = _button("继续", func(): continue_requested.emit())
	_continue_btn.visible = false

	_buttons = [
		_continue_btn,
		_button("开始游戏", func(): start_requested.emit()),
		_button("玩法说明", func(): _set_help(true)),
		_button("设置", func(): settings_requested.emit()),
		_button("概率公示", func(): odds_requested.emit()),
		_button("退出游戏", func(): quit_requested.emit()),
	]

	_footer = _label("v2.0 · Godot 4.7 · 1280×720", 12, COL_DIM)
	_hint = _label("Enter 或 F 开始游戏", 13, COL_GOLD)

	_build_help()


func _build_help() -> void:
	_help = Control.new()
	_help.mouse_filter = Control.MOUSE_FILTER_STOP
	_help.visible = false
	add_child(_help)

	_help_panel = Panel.new()
	_help_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := _skin.panel_style()
	if sb != null:
		_help_panel.add_theme_stylebox_override("panel", sb)
	_help.add_child(_help_panel)

	_help_title = Label.new()
	_help_title.text = "玩法与操作"
	_help_title.add_theme_font_size_override("font_size", 28)
	_help_title.add_theme_color_override("font_color", COL_GOLD)
	_help.add_child(_help_title)

	_help_body = Label.new()
	_help_body.add_theme_font_size_override("font_size", 15)
	_help_body.add_theme_color_override("font_color", COL_TEXT)
	_help_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_help_body.text = """【目标】守住中央水晶，撑过 5 波（单局 15–20 分钟）。
【节奏】搜集期出城开箱 → 建设期买建材修墙 → 战斗期守墙 → 波末三选一。

【操作】
  WASD          移动
  鼠标          瞄准（准星跟随光标）
  左键          攻击 / 锤修墙 / 刀近战
  右键          翻滚（0.28s 冲刺 + 0.2s 无敌帧，冷却 0.9s）
  空格（按住）   精确瞄准：视野拉近、移速 ×0.6、散布 ×0.5
  Shift         冲刺
  1 / 2         切换枪槽        3 锤        4 刀
  B / Tab       背包（随时可开，打开时游戏暂停）
  F             开始 / 推进阶段        Esc 关闭本页

【提示】墙不挡子弹：站在城内也能越过墙顶射击。城墙被打破口后，敌人会直接冲向水晶——那才是失败点。"""
	_help.add_child(_help_body)

	_help_close = Button.new()
	_help_close.text = "关闭"
	_help_close.custom_minimum_size = Vector2(200, 46)
	_help_close.pressed.connect(func(): _set_help(false))
	_help.add_child(_help_close)


func _label(text: String, size_px: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = BTN_SIZE
	b.size = BTN_SIZE
	b.add_theme_font_size_override("font_size", 20)
	b.pressed.connect(cb)
	add_child(b)
	return b


## CanvasLayer 下的 Control 不会自动铺满，手动同步并重排
func _sync_size() -> void:
	position = Vector2.ZERO
	size = get_viewport_rect().size
	_layout()
	queue_redraw()


## 有存档时显示「继续 · 建设期 · 第 2 波」；detail 由 app 层从存档头读出来
func set_can_continue(on: bool, detail: String = "") -> void:
	if _continue_btn == null:
		return
	_continue_btn.visible = on
	_continue_btn.text = "继续" if detail == "" else "继续 · " + detail
	_layout()


func _layout() -> void:
	var w := size.x
	var h := size.y
	_title.position = Vector2(0, h * 0.22)
	_title.size = Vector2(w, 84)
	_subtitle.position = Vector2(0, h * 0.22 + 92)
	_subtitle.size = Vector2(w, 28)
	var top := h * 0.39
	var shown := 0
	for i in range(_buttons.size()):
		var b: Button = _buttons[i]
		if not b.visible:
			continue
		b.position = Vector2((w - BTN_SIZE.x) * 0.5, top + BTN_GAP * float(shown))
		b.size = BTN_SIZE
		shown += 1
	_footer.position = Vector2(0, h - 46)
	_footer.size = Vector2(w, 20)
	_hint.position = Vector2(0, h - 74)
	_hint.size = Vector2(w, 20)

	var hp := HELP_SIZE
	_help_panel.position = (size - hp) * 0.5
	_help_panel.size = hp
	_help_title.position = _help_panel.position + Vector2(28, 20)
	_help_title.size = Vector2(hp.x - 56, 36)
	_help_body.position = _help_panel.position + Vector2(28, 68)
	_help_body.size = Vector2(hp.x - 56, hp.y - 148)
	_help_close.position = _help_panel.position + Vector2((hp.x - 200) * 0.5, hp.y - 66)
	_help_close.size = Vector2(200, 46)


func _set_help(on: bool) -> void:
	_help.visible = on
	# 说明打开时挡住下层按钮，避免误点到「退出游戏」
	for b in _buttons:
		(b as Button).disabled = on
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COL_BG)
	var w := size.x
	var h := size.y
	# 标题上下两条暖金细线，给暗底一个结构
	draw_line(Vector2(w * 0.22, h * 0.22 - 16), Vector2(w * 0.78, h * 0.22 - 16), COL_GOLD * Color(1, 1, 1, 0.45), 1.0)
	draw_line(Vector2(w * 0.30, h * 0.22 + 126), Vector2(w * 0.70, h * 0.22 + 126), Color(1, 1, 1, 0.10), 1.0)
	if _help.visible:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.55))


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not input_enabled:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var k := key.physical_keycode
	if _help.visible:
		if k == KEY_ESCAPE or k == KEY_F:
			_set_help(false)
			get_viewport().set_input_as_handled()
		return
	if k == KEY_ENTER or k == KEY_KP_ENTER or k == KEY_F:
		start_requested.emit()
		get_viewport().set_input_as_handled()
	elif k == KEY_ESCAPE:
		quit_requested.emit()
		get_viewport().set_input_as_handled()