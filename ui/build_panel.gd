class_name BuildPanel
extends Control
## 建造面板（2026-11-10）：建设期常驻左侧，列出四种建造物的价格/上限/当前状态。
## 只读 app 注入的 BuildSystem.ui_state()；点击卡片是「选中放置」或「立即扩容」，
## 真正的扣费/放置/拒绝都在 core 的 BuildSystem 里。

signal build_requested(id: String)
signal free_build_toggled(on: bool)
signal demolish_toggled(on: bool)

const PANEL_SIZE := Vector2(304, 424)
const COL_GOLD := Color(0.95, 0.80, 0.42)
const COL_DIM := Color(0.62, 0.66, 0.72)
const COL_WARN := Color(0.92, 0.55, 0.35)
const COL_TEXT := Color(0.90, 0.92, 0.95)
const CARD_H := 72

var _skin := HudSkin.new()
var _panel: Panel
var _title: Label
var _list: VBoxContainer
var _hint: Label
var _free_build: Button
var _demolish: Button
var _signature := ""
var _info: Dictionary = {}
var _snap: Dictionary = {}


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = _skin.build_theme()
	size = PANEL_SIZE
	position = Vector2(18, 196)

	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := _skin.panel_style()
	if sb != null:
		_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	_panel.position = Vector2.ZERO
	_panel.size = PANEL_SIZE

	_title = _label("建造 · 建设期", 16, COL_GOLD, Vector2(12, 10), Vector2(280, 24))
	_list = VBoxContainer.new()
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list.position = Vector2(12, 40)
	_list.size = Vector2(280, 4 * CARD_H + 3 * 4)
	_list.add_theme_constant_override("separation", 4)
	add_child(_list)

	_hint = _label("", 11, COL_DIM, Vector2(12, 344), Vector2(280, 34))
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_free_build = Button.new()
	_free_build.text = "自由建造（V）"
	_free_build.toggle_mode = true
	_free_build.position = Vector2(12, 384)
	_free_build.size = Vector2(136, 26)
	_free_build.custom_minimum_size = Vector2(136, 26)
	_free_build.add_theme_font_size_override("font_size", 11)
	_free_build.mouse_filter = Control.MOUSE_FILTER_STOP
	_free_build.toggled.connect(func(on: bool): free_build_toggled.emit(on))
	add_child(_free_build)

	_demolish = Button.new()
	_demolish.text = "拆除（X）"
	_demolish.toggle_mode = true
	_demolish.position = Vector2(156, 384)
	_demolish.size = Vector2(136, 26)
	_demolish.custom_minimum_size = Vector2(136, 26)
	_demolish.add_theme_font_size_override("font_size", 11)
	_demolish.mouse_filter = Control.MOUSE_FILTER_STOP
	_demolish.toggled.connect(func(on: bool): demolish_toggled.emit(on))
	add_child(_demolish)

	get_viewport().size_changed.connect(_layout)
	_layout()


func _layout() -> void:
	position = Vector2(18, maxf(150.0, minf(196.0, get_viewport_rect().size.y - PANEL_SIZE.y - 100.0)))
	size = PANEL_SIZE


func _label(text: String, size_px: int, color: Color, pos: Vector2, box: Vector2) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.size = box
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func sync(snap: Dictionary, info: Dictionary) -> void:
	_snap = snap
	_info = info
	var sig := _signature_of(snap, info)
	if sig != _signature:
		_signature = sig
		_rebuild(snap, info)
	_free_build.set_pressed_no_signal(str(info.get("selected", "")) != "")
	_demolish.set_pressed_no_signal(bool(info.get("demolish_mode", false)))
	_hint.text = _hint_text(info)
	_hint.add_theme_color_override("font_color",
		COL_WARN if bool(info.get("demolish_mode", false)) else COL_DIM)


func _signature_of(snap: Dictionary, info: Dictionary) -> String:
	var parts: PackedStringArray = []
	for it in info.get("items", []):
		parts.append("%s:%d:%s:%s" % [str(it["id"]), int(it["count"]),
			str(it["blocked"]), str(it["reason"])])
	return "%d|%d|%d|%d|%d|%s|%s|%s" % [
		int(snap.get("phase", 0)), int(snap.get("coin", 0)), int(snap.get("brick", 0)),
		int(snap.get("metal", 0)), int(snap.get("ammo", 0)),
		str(info.get("selected", "")), str(bool(info.get("demolish_mode", false))),
		"/".join(parts),
	]


func _rebuild(snap: Dictionary, info: Dictionary) -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	var selected := str(info.get("selected", ""))
	var items: Array = info.get("items", [])
	for i in range(items.size()):
		var it: Dictionary = items[i]
		var id := str(it["id"])
		var b := Button.new()
		b.toggle_mode = true
		b.button_pressed = selected == id
		b.custom_minimum_size = Vector2(280, CARD_H)
		b.add_theme_font_size_override("font_size", 11)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var status := "✔ 可建造"
		if bool(it["blocked"]):
			status = "✘ " + str(it["reason"])
		elif selected == id:
			status = "▶ 自由建造中 · 左键连续放置"
		elif str(it.get("placement", "")) == "self":
			status = "✔ 立即扩容"
		b.text = "%d %s · %s\n%s\n%s" % [
			i + 1, str(it["name"]), str(it.get("count_label", it["limit_label"])),
			_cost_line(it.get("cost", {})), status,
		]
		b.tooltip_text = "%s\n%s" % [str(it.get("desc", "")), str(it.get("effect", ""))]
		b.disabled = bool(it["blocked"])
		b.add_theme_color_override("font_color", COL_GOLD if selected == id else COL_TEXT)
		b.add_theme_color_override("font_disabled_color", Color(0.52, 0.55, 0.60))
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		b.pressed.connect(func(): build_requested.emit(id))
		_list.add_child(b)


func _cost_line(cost: Dictionary) -> String:
	var parts: PackedStringArray = []
	if int(cost.get("coin", 0)) > 0:
		parts.append("金 %d" % int(cost["coin"]))
	if int(cost.get("brick", 0)) > 0:
		parts.append("砖 %d" % int(cost["brick"]))
	if int(cost.get("metal", 0)) > 0:
		parts.append("金属 %d" % int(cost["metal"]))
	if int(cost.get("ammo", 0)) > 0:
		parts.append("弹 %d" % int(cost["ammo"]))
	var raw := " + ".join(parts) if not parts.is_empty() else "免费"
	return "%s\n≈%dG" % [raw, int(cost.get("equivalent", 0))]


func _hint_text(info: Dictionary) -> String:
	if bool(info.get("demolish_mode", false)):
		var target: Dictionary = info.get("demolish_target", {})
		if target.is_empty():
			return "拆除模式：光标指向木箱/炮台，或自建城墙段。"
		if String(target.get("kind", "")) == "building":
			var kind := ""
			for b in _snap.get("buildings", []):
				if int(b.get("id", -1)) == int(target.get("id", -2)):
					kind = str(b.get("kind", ""))
			if kind == "crate":
				return "拆除木箱：返还 50% 建造资源，箱内 100% 掉落。"
			return "拆除炮台：返还 50% 建造资源。"
		var idx := int(target.get("index", -1))
		var walls: Array = _snap.get("wall", [])
		if idx >= 0 and idx < walls.size():
			if bool(walls[idx].get("built", false)):
				return "拆除自建城墙段：返还 50% 建造资源（不退本波名额）。"
			return "初始城墙是地形，不能拆除。"
		return "拆除模式：把光标移到目标上。"
	var selected := str(info.get("selected", ""))
	if selected != "":
		for it in info.get("items", []):
			if String(it.get("id", "")) == selected and bool(it.get("blocked", false)):
				return "无法建造：%s" % str(it.get("reason", ""))
		var reason := str(info.get("preview_reason", ""))
		if selected == "backpack":
			return "背包扩容：点击卡片立即生效，+10 格。"
		if reason != "":
			return "放置位置非法：%s" % reason
		return "自由建造中：左键连续放置 · V / 右键 / Esc 退出。"
	return "按 V 进入自由建造；或点击建造物卡片。拆除按 X。"


func invalidate() -> void:
	_signature = ""
	if visible and _snap is Dictionary:
		sync(_snap, _info)