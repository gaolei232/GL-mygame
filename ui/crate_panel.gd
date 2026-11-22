class_name CratePanel
extends Control
## 木箱仓库（2026-11-10）：靠近木箱 3m 内按 R 打开的模态界面。
## 左：5×5 格；右：玩家资源存取 + 背包物品存入。
## 只读 snapshot，所有写入走信号回 App → BuildSystem。

signal deposit_item(uid: int)
signal withdraw_slot(slot: int)
signal deposit_resource(kind: String, amount: int)
signal withdraw_resource(kind: String, amount: int)
signal deposit_all_items
signal closed

const PANEL_SIZE := Vector2(880, 560)
const CELL := 64.0
const GAP := 6.0
const GRID_ORIGIN := Vector2(28, 86)
const RIGHT_X := 396.0
const TIER_COLORS := [
	Color(0.81, 0.83, 0.86), Color(0.50, 0.79, 0.54), Color(0.42, 0.68, 0.94), Color(0.88, 0.70, 0.30),
]
const RES := [
	["coin", "金币", Color(0.95, 0.80, 0.42)],
	["brick", "砖块", Color(0.78, 0.62, 0.44)],
	["metal", "金属", Color(0.72, 0.78, 0.86)],
	["ammo", "弹药", Color(0.95, 0.72, 0.50)],
]

var _skin := HudSkin.new()
var _panel: Panel
var _title: Label
var _sub: Label
var _grid: Control
var _res_title: Label
var _res_box: VBoxContainer
var _bag_title: Label
var _bag_scroll: ScrollContainer
var _bag_list: VBoxContainer
var _hint: Label
var _close: Button
var _deposit_all: Button
var _crate_id := -1
var _snap: Dictionary = {}
var _signature := ""
var _stored: Array = []
var _stored_cols := 5
var _stored_rows := 5


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = _skin.build_theme()
	size = PANEL_SIZE

	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := _skin.panel_style()
	if sb != null:
		_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)

	_title = _label("木箱", 22, Color(0.95, 0.80, 0.42), Vector2(28, 16), Vector2(720, 30))
	_sub = _label("", 13, Color(0.62, 0.66, 0.72), Vector2(28, 48), Vector2(700, 22))
	_grid = Control.new()
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.position = GRID_ORIGIN
	_grid.size = Vector2(CELL * 5 + GAP * 4, CELL * 5 + GAP * 4)
	add_child(_grid)

	_res_title = _label("玩家资源 / 箱内", 15, Color(0.95, 0.80, 0.42),
		Vector2(RIGHT_X, 86), Vector2(420, 22))
	_res_box = VBoxContainer.new()
	_res_box.position = Vector2(RIGHT_X, 112)
	_res_box.size = Vector2(456, 150)
	_res_box.add_theme_constant_override("separation", 4)
	add_child(_res_box)

	_bag_title = _label("背包物品（点击存入）", 15, Color(0.95, 0.80, 0.42),
		Vector2(RIGHT_X, 274), Vector2(320, 22))
	_deposit_all = Button.new()
	_deposit_all.text = "全部存入"
	_deposit_all.position = Vector2(RIGHT_X + 344, 270)
	_deposit_all.size = Vector2(112, 26)
	_deposit_all.add_theme_font_size_override("font_size", 12)
	_deposit_all.pressed.connect(func(): deposit_all_items.emit())
	add_child(_deposit_all)

	_bag_scroll = ScrollContainer.new()
	_bag_scroll.position = Vector2(RIGHT_X, 300)
	_bag_scroll.size = Vector2(456, 204)
	_bag_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_bag_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(_bag_scroll)
	_bag_list = VBoxContainer.new()
	_bag_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bag_list.add_theme_constant_override("separation", 3)
	_bag_scroll.add_child(_bag_list)

	_hint = _label("左键箱内格子取出整堆/整件 · 右侧点击背包物品存入 · R / Esc 关闭",
		11, Color(0.62, 0.66, 0.72), Vector2(28, 520), Vector2(820, 24))

	_close = Button.new()
	_close.text = "关闭 R"
	_close.position = Vector2(PANEL_SIZE.x - 112, 16)
	_close.size = Vector2(84, 28)
	_close.add_theme_font_size_override("font_size", 12)
	_close.pressed.connect(func(): closed.emit())
	add_child(_close)

	get_viewport().size_changed.connect(_layout)
	_layout()


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


func _layout() -> void:
	position = Vector2.ZERO
	size = get_viewport_rect().size
	var origin := ((size - PANEL_SIZE) * 0.5).floor()
	_panel.position = origin
	_panel.size = PANEL_SIZE
	_title.position = origin + Vector2(28, 16)
	_sub.position = origin + Vector2(28, 48)
	_grid.position = origin + GRID_ORIGIN
	_res_title.position = origin + Vector2(RIGHT_X, 86)
	_res_box.position = origin + Vector2(RIGHT_X, 112)
	_bag_title.position = origin + Vector2(RIGHT_X, 274)
	_deposit_all.position = origin + Vector2(RIGHT_X + 344, 270)
	_bag_scroll.position = origin + Vector2(RIGHT_X, 300)
	_hint.position = origin + Vector2(28, 520)
	_close.position = origin + Vector2(PANEL_SIZE.x - 112, 16)
	queue_redraw()


func open(crate_id: int, snap: Dictionary) -> void:
	_crate_id = crate_id
	_snap = snap
	_signature = ""
	visible = true
	_sync(snap)


func close() -> void:
	visible = false


func sync(snap: Dictionary) -> void:
	if not visible:
		return
	_snap = snap
	_sync(snap)


func _find_crate(snap: Dictionary) -> Dictionary:
	for b in snap.get("buildings", []):
		if int(b.get("id", -1)) == _crate_id and str(b.get("kind", "")) == "crate":
			return b
	return {}


func _sync(snap: Dictionary) -> void:
	var crate := _find_crate(snap)
	if crate.is_empty():
		close()
		return
	var stored: Array = crate.get("stored", [])
	var used := int(crate.get("stored_used", 0))
	var total := int(crate.get("stored_total", 25))
	_title.text = "木箱 #%d · HP %d / %d · 存储 %d / %d" % [
		int(crate.get("index", 1)), int(crate.get("hp", 0)), int(crate.get("max_hp", 0)),
		used, total,
	]
	_sub.text = "存取半径 3m · 摧毁后 100% 掉落（60s）· 资源堆叠 / 物品各占 1 格"
	var sig := "%d|%s|%s|%s|%d|%d|%d|%d|%s" % [
		_crate_id, str(stored), str(snap.get("items", [])), str(snap.get("bag_capacity", 0)),
		int(snap.get("coin", 0)), int(snap.get("brick", 0)), int(snap.get("metal", 0)),
		int(snap.get("ammo", 0)), str(snap.get("bag_rows", 2)),
	]
	_stored = stored
	_stored_cols = int(crate.get("stored_cols", 5))
	_stored_rows = int(crate.get("stored_rows", 5))
	if sig != _signature:
		_signature = sig
		_rebuild_grid()
		_rebuild_resources(snap)
		_rebuild_bag(snap)
	queue_redraw()


func _rebuild_grid() -> void:
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	for i in range(_stored.size()):
		var slot: Dictionary = _stored[i]
		var b := Button.new()
		b.position = Vector2((i % _stored_cols) * (CELL + GAP), int(i / _stored_cols) * (CELL + GAP))
		b.size = Vector2(CELL, CELL)
		b.custom_minimum_size = b.size
		b.add_theme_font_size_override("font_size", 10)
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		if slot.is_empty():
			b.disabled = true
			b.flat = true
			b.text = ""
			b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.12))
		else:
			var kind := String(slot.get("kind", ""))
			if kind == "item":
				var item: Dictionary = slot.get("item", {})
				var tier := clampi(int(item.get("tier", 0)), 0, 3)
				b.text = "%s\n◆" % str(item.get("name", "物品"))
				b.add_theme_color_override("font_color", TIER_COLORS[tier])
				b.tooltip_text = "%s · 左键取出" % str(item.get("desc", ""))
			else:
				b.text = "%s\n%d" % [_res_name(kind), int(slot.get("amount", 0))]
				b.add_theme_color_override("font_color", _res_color(kind))
				b.tooltip_text = "左键取出整堆"
			var idx := i
			b.pressed.connect(func(): withdraw_slot.emit(idx))
		_grid.add_child(b)


func _rebuild_resources(snap: Dictionary) -> void:
	for c in _res_box.get_children():
		_res_box.remove_child(c)
		c.queue_free()
	var sums := {}
	for slot in _stored:
		var kind := String((slot as Dictionary).get("kind", ""))
		if kind == "" or kind == "item":
			continue
		sums[kind] = int(sums.get(kind, 0)) + int((slot as Dictionary).get("amount", 0))
	for row in RES:
		var kind := String(row[0])
		var name := String(row[1])
		var color: Color = row[2]
		var owned := int(snap.get(kind, 0))
		var inside := int(sums.get(kind, 0))
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		var l1 := Label.new()
		l1.text = name
		l1.custom_minimum_size = Vector2(44, 26)
		l1.add_theme_font_size_override("font_size", 12)
		l1.add_theme_color_override("font_color", color)
		h.add_child(l1)
		var l2 := Label.new()
		l2.text = "持有 %d" % owned
		l2.custom_minimum_size = Vector2(100, 26)
		l2.add_theme_font_size_override("font_size", 12)
		h.add_child(l2)
		var l3 := Label.new()
		l3.text = "箱内 %d" % inside
		l3.custom_minimum_size = Vector2(100, 26)
		l3.add_theme_font_size_override("font_size", 12)
		l3.add_theme_color_override("font_color", color)
		h.add_child(l3)
		var b1 := Button.new()
		b1.text = "存 100"
		b1.custom_minimum_size = Vector2(72, 26)
		b1.add_theme_font_size_override("font_size", 11)
		b1.disabled = owned <= 0
		var k := kind
		b1.pressed.connect(func(): deposit_resource.emit(k, 100))
		h.add_child(b1)
		var b2 := Button.new()
		b2.text = "取 100"
		b2.custom_minimum_size = Vector2(72, 26)
		b2.add_theme_font_size_override("font_size", 11)
		b2.disabled = inside <= 0
		b2.pressed.connect(func(): withdraw_resource.emit(k, 100))
		h.add_child(b2)
		_res_box.add_child(h)


func _rebuild_bag(snap: Dictionary) -> void:
	for c in _bag_list.get_children():
		_bag_list.remove_child(c)
		c.queue_free()
	var items: Array = snap.get("items", [])
	_deposit_all.disabled = items.is_empty()
	if items.is_empty():
		var l := Label.new()
		l.text = "背包里没有可存入的物品。"
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
		_bag_list.add_child(l)
		return
	for it in items:
		var tier := clampi(int(it.get("tier", 0)), 0, 3)
		var b := Button.new()
		b.text = "存入  %s  ·  %s" % [str(it.get("name", "?")), str(it.get("desc", ""))]
		b.custom_minimum_size = Vector2(440, 28)
		b.add_theme_font_size_override("font_size", 11)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_color_override("font_color", TIER_COLORS[tier])
		var uid := int(it.get("uid", -1))
		b.pressed.connect(func(): deposit_item.emit(uid))
		_bag_list.add_child(b)


func _res_name(kind: String) -> String:
	for row in RES:
		if String(row[0]) == kind:
			return String(row[1])
	return kind


func _res_color(kind: String) -> Color:
	for row in RES:
		if String(row[0]) == kind:
			return row[2]
	return Color.WHITE


func _draw() -> void:
	if not visible:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.04, 0.82))
	if _grid == null:
		return
	for y in range(_stored_rows):
		for x in range(_stored_cols):
			var rect := Rect2(_grid.position + Vector2(x * (CELL + GAP), y * (CELL + GAP)),
				Vector2(CELL, CELL))
			draw_rect(rect, Color(0.07, 0.08, 0.10, 0.95))
			draw_rect(rect, Color(1, 1, 1, 0.07), false, 1.0)