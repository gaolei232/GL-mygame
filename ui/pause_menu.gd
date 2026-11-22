class_name PauseMenu
extends Control
## 暂停面板（P1-1）：黑底 + 三个按钮。只发信号，不碰 Sim。
## 由 GameApp 控制显隐；Esc / P 在 app 层统一处理（避免和主菜单抢按键）。

signal resume_requested
signal settings_requested
signal odds_requested
signal title_requested

const COL_DIM := Color(0.62, 0.66, 0.72)
const COL_TEXT := Color(0.92, 0.94, 0.97)
const BTN_SIZE := Vector2(320, 50)

var _skin := HudSkin.new()
var _title: Label
var _buttons: Array = []


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = _skin.build_theme()
	_title = Label.new()
	_title.text = "暂 停"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 40)
	_title.add_theme_color_override("font_color", COL_TEXT)
	add_child(_title)

	_buttons = [
		_button("继续游戏（Esc）", func(): resume_requested.emit()),
		_button("设置", func(): settings_requested.emit()),
		_button("概率公示", func(): odds_requested.emit()),
		_button("返回主菜单", func(): title_requested.emit()),
	]
	get_viewport().size_changed.connect(_layout)
	_layout()


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = BTN_SIZE
	b.add_theme_font_size_override("font_size", 18)
	b.pressed.connect(cb)
	add_child(b)
	return b


func _layout() -> void:
	position = Vector2.ZERO
	size = get_viewport_rect().size
	_title.position = Vector2(0, size.y * 0.30)
	_title.size = Vector2(size.x, 48)
	for i in range(_buttons.size()):
		var b: Button = _buttons[i]
		b.position = Vector2((size.x - BTN_SIZE.x) * 0.5, size.y * 0.40 + 62.0 * float(i))
		b.size = BTN_SIZE


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.04, 0.05, 0.72))
	draw_line(Vector2(size.x * 0.30, size.y * 0.30 + 60), Vector2(size.x * 0.70, size.y * 0.30 + 60),
		Color(1, 1, 1, 0.12), 1.0)