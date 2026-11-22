extends Control
## 帮助 / 键位说明面板（2026-11-15）：H 键或主菜单均可打开。
## 只读展示，不含任何判定；打开时由 app 冻结 sim（与背包同样的模态规则）。

signal closed

const LINES := [
	["移动", "W A S D（相机相对方向）"],
	["瞄准 / 射击", "鼠标位置即准星 · 按住左键开火"],
	["冲刺", "按住 Shift（移速 ×2）"],
	["翻滚", "鼠标右键（0.28s，短暂无敌）"],
	["主动技能 · 瞬移", "Q：向移动方向瞬移 3m，冷却 10s"],
	["精确瞄准", "按住 空格（移速 ×0.6，散布 ×0.5）"],
	["切换槽位", "1 弩 · 2 副枪 · 3 锤 · 4 刀"],
	["上下文操作", "F：开始 / 回城 / 开波"],
	["搜箱", "靠近即自动扫描，扫完双击格内物资拾取"],
	["背包", "B 或 Tab（资源堆占格、可叠加、右键丢弃）"],
	["建造 / 拆除", "建设期按 E 放置 · 详见建造面板"],
	["暂停 / 设置", "Esc 或 P"],
	["帮助", "H"],
]

var _panel: Panel
var _title: Label
var _body: RichTextLabel
var _hint: Label


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	_title = Label.new()
	_title.text = "操作说明"
	_title.add_theme_font_size_override("font_size", 30)
	_title.add_theme_color_override("font_color", Color(0.95, 0.80, 0.42))
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_title)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.scroll_active = false
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_theme_font_size_override("normal_font_size", 13)
	add_child(_body)

	_hint = Label.new()
	_hint.text = "H / Esc 关闭"
	_hint.add_theme_font_size_override("font_size", 14)
	_hint.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hint)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.06, 0.08, 0.95)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(22)
	_panel.add_theme_stylebox_override("panel", sb)

	_build_text()
	get_viewport().size_changed.connect(_layout)
	_layout()


func _build_text() -> void:
	var parts: PackedStringArray = []
	for row in LINES:
		parts.append("[color=#e8c766]%s[/color]\n    %s" % [row[0], row[1]])
	_body.text = "\n".join(parts)


func _layout() -> void:
	var vp := get_viewport_rect().size
	var w := 660.0
	var h := 600.0
	_panel.position = Vector2((vp.x - w) * 0.5, (vp.y - h) * 0.5)
	_panel.size = Vector2(w, h)
	_title.position = _panel.position + Vector2(26, 20)
	_body.position = _panel.position + Vector2(26, 66)
	_body.size = Vector2(w - 52, h - 96)
	_hint.position = _panel.position + Vector2(26, h - 34)


func open() -> void:
	visible = true
	_layout()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()