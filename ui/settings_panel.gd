class_name SettingsPanel
extends Control
## 设置面板（P1-2）：主音量 / 全屏 / 画质。只发信号，应用与持久化在 app 层。
## 画质只映射 MSAA（项目里唯一的画质开关），不假装有更多档位。

signal closed
signal changed(values: Dictionary)

const PANEL_SIZE := Vector2(520, 336)
const ROW_H := 48.0

var _skin := HudSkin.new()
var _panel: Panel
var _title: Label
var _volume: HSlider
var _volume_label: Label
var _fullscreen: CheckButton
var _quality: OptionButton
var _close: Button
var _syncing := false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = _skin.build_theme()

	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := _skin.panel_style()
	if sb != null:
		_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	_title = Label.new()
	_title.text = "设 置"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 28)
	_title.add_theme_color_override("font_color", Color(0.95, 0.80, 0.42))
	add_child(_title)

	_volume_label = Label.new()
	_volume_label.add_theme_font_size_override("font_size", 15)
	_volume_label.add_theme_color_override("font_color", Color(0.92, 0.94, 0.97))
	add_child(_volume_label)

	_volume = HSlider.new()
	_volume.min_value = 0.0
	_volume.max_value = 100.0
	_volume.step = 5.0
	_volume.custom_minimum_size = Vector2(240, 24)
	_volume.value_changed.connect(_on_volume_changed)
	add_child(_volume)

	_fullscreen = CheckButton.new()
	_fullscreen.text = "全屏"
	_fullscreen.add_theme_font_size_override("font_size", 15)
	_fullscreen.toggled.connect(func(on: bool): _emit_change())
	add_child(_fullscreen)

	_quality = OptionButton.new()
	_quality.add_item("低 · 无抗锯齿")
	_quality.add_item("中 · MSAA 2×")
	_quality.add_item("高 · MSAA 4×")
	_quality.item_selected.connect(func(_i: int): _emit_change())
	add_child(_quality)

	_close = Button.new()
	_close.text = "关闭（Esc）"
	_close.custom_minimum_size = Vector2(200, 44)
	_close.pressed.connect(func(): closed.emit())
	add_child(_close)

	get_viewport().size_changed.connect(_layout)
	_layout()


func _layout() -> void:
	position = Vector2.ZERO
	size = get_viewport_rect().size
	var origin := ((size - PANEL_SIZE) * 0.5).floor()
	_panel.position = origin
	_panel.size = PANEL_SIZE
	_title.position = origin + Vector2(0, 18)
	_title.size = Vector2(PANEL_SIZE.x, 34)

	var rows := origin + Vector2(36, 72)
	_volume_label.position = rows
	_volume_label.size = Vector2(150, 26)
	_volume.position = rows + Vector2(160, 0)
	_volume.size = Vector2(300, 26)

	_fullscreen.position = rows + Vector2(0, ROW_H * 1.2)
	_fullscreen.size = Vector2(160, 32)

	_quality.position = rows + Vector2(160, ROW_H * 1.2)
	_quality.size = Vector2(300, 32)

	_close.position = origin + Vector2((PANEL_SIZE.x - 200) * 0.5, PANEL_SIZE.y - 62)
	_close.size = Vector2(200, 44)


## 打开面板并回填当前值（回填过程不触发 changed，避免「打开就写盘」）
func open(values: Dictionary) -> void:
	_syncing = true
	_volume.value = int(round(clampf(float(values.get("volume", 0.8)), 0.0, 1.0) * 100.0))
	_fullscreen.button_pressed = bool(values.get("fullscreen", false))
	_quality.selected = clampi(int(values.get("quality", 1)), 0, 2)
	_sync_volume_label()
	_syncing = false
	visible = true


func close() -> void:
	visible = false


func values() -> Dictionary:
	return {
		"volume": float(_volume.value) / 100.0,
		"fullscreen": _fullscreen.button_pressed,
		"quality": _quality.selected,
	}


func _on_volume_changed(_v: float) -> void:
	_sync_volume_label()
	_emit_change()


func _sync_volume_label() -> void:
	_volume_label.text = "主音量 %d%%" % int(_volume.value)


func _emit_change() -> void:
	if _syncing:
		return
	changed.emit(values())


func _draw() -> void:
	if not visible:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.04, 0.78))