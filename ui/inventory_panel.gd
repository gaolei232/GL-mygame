class_name InventoryPanel
extends Control
## 背包（2026-11-10）：B 键开关的模态界面。
## 左：装备位（2 词条 + 1 配件）与属性合计；右：5×2 网格，物品按稀有度占位
## （普通 1×1 / 精良 1×2 / 稀有 2×1 / 传说 2×2）。左键装备/卸下、右键卖出。
## 只读 snapshot，所有写入走信号回 app。

signal equip_requested(uid: int)
signal unequip_requested(uid: int)
signal sell_requested(uid: int)
signal drop_requested(uid: int)
signal closed

const PANEL_SIZE := Vector2(880, 548)
const CELL := 86.0
const GAP := 8.0
const BAG_AREA := Vector2(500, 344)
const SLOT_NAMES := {"trait": "词条", "attachment": "配件"}
const TIER_COLORS := [
	Color(0.81, 0.83, 0.86), Color(0.50, 0.79, 0.54), Color(0.42, 0.68, 0.94), Color(0.88, 0.70, 0.30),
]
const STAT_LABELS := {
	"dmg": "伤害", "rate": "射击间隔", "spread": "散布", "repair": "修墙量", "speed": "移速",
}

var _skin := HudSkin.new()
var _panel: Panel
var _title: Label
var _cap: Label
var _slots_box: VBoxContainer
var _bag_label: Label
var _bag_area: Control
var _stats: Label
var _hint: Label
var _signature := ""
var _snap: Dictionary = {}
var _cell := CELL


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

	_title = _label("背  包", 30, Color(0.95, 0.80, 0.42), HORIZONTAL_ALIGNMENT_LEFT)
	_cap = _label("", 15, Color(0.62, 0.66, 0.72), HORIZONTAL_ALIGNMENT_RIGHT)

	_slots_box = VBoxContainer.new()
	_slots_box.add_theme_constant_override("separation", 8)
	add_child(_slots_box)

	_bag_label = _label("", 16, Color(0.95, 0.80, 0.42), HORIZONTAL_ALIGNMENT_LEFT)
	_bag_area = Control.new()
	_bag_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bag_area)

	_stats = _label("", 13, Color(0.72, 0.78, 0.86), HORIZONTAL_ALIGNMENT_LEFT)
	_hint = _label("左键 装备 / 卸下 · 右键 卖出 · 资源堆右键 丢弃 · B / Esc 关闭", 12,
		Color(0.62, 0.66, 0.72), HORIZONTAL_ALIGNMENT_LEFT)

	get_viewport().size_changed.connect(_layout)
	_layout()


func _label(text: String, size_px: int, color: Color, align: int) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
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
	_title.position = origin + Vector2(28, 18)
	_title.size = Vector2(200, 40)
	_cap.position = origin + Vector2(PANEL_SIZE.x - 268, 26)
	_cap.size = Vector2(240, 24)
	_slots_box.position = origin + Vector2(28, 74)
	_slots_box.size = Vector2(300, 360)
	_bag_label.position = origin + Vector2(352, 74)
	_bag_label.size = Vector2(400, 24)
	_bag_area.position = origin + Vector2(352, 104)
	_bag_area.size = BAG_AREA
	_stats.position = origin + Vector2(28, PANEL_SIZE.y - 90)
	_stats.size = Vector2(PANEL_SIZE.x - 56, 24)
	_hint.position = origin + Vector2(28, PANEL_SIZE.y - 58)
	_hint.size = Vector2(PANEL_SIZE.x - 56, 22)


func open(snap: Dictionary) -> void:
	_snap = snap
	_signature = ""
	visible = true
	_sync(snap)


func close() -> void:
	visible = false


## 每帧同步：只有签名（物品/装备/占位）变化才重建，避免点击被重建吞掉
func sync(snap: Dictionary) -> void:
	if not visible:
		return
	_snap = snap
	_sync(snap)


func _sync(snap: Dictionary) -> void:
	var sig := _snapshot_signature(snap)
	if sig == _signature:
		return
	_signature = sig
	var used := int(snap.get("bag_used", 0))
	_cap.text = "背包 %d / %d 格 · %d 件" % [used, int(snap.get("bag_capacity", 0)),
		(snap.get("items", []) as Array).size()]
	_bag_label.text = "背包（%d×%d 格）" % [int(snap.get("bag_cols", 5)), int(snap.get("bag_rows", 2))]
	_rebuild_slots(snap)
	_rebuild_bag(snap)
	_rebuild_stats(snap)


func _snapshot_signature(snap: Dictionary) -> String:
	var parts: PackedStringArray = []
	for it in snap.get("items", []):
		parts.append("%d:%s" % [int(it["uid"]), str(it["equipped"])])
	return "%s|%s|%s|%d|%d" % ["/".join(parts), str(snap.get("bag_layout", [])),
		str(snap.get("mods", {})), int(snap.get("bag_rows", 2)),
		int(snap.get("bag_capacity", 0))]


func _rebuild_slots(snap: Dictionary) -> void:
	for c in _slots_box.get_children():
		_slots_box.remove_child(c)
		c.queue_free()
	var caps: Dictionary = snap.get("slot_caps", {})
	var equipped_items: Array = []
	for it in snap.get("items", []):
		if bool(it["equipped"]):
			equipped_items.append(it)

	var header := Label.new()
	header.text = "装备位"
	header.add_theme_font_size_override("font_size", 16)
	header.add_theme_color_override("font_color", Color(0.95, 0.80, 0.42))
	_slots_box.add_child(header)

	for kind in ["trait", "attachment"]:
		var cap := int(caps.get(kind, 0))
		var shown := 0
		for it in equipped_items:
			if str(it["kind"]) != kind:
				continue
			if shown >= cap:
				break
			shown += 1
			_slots_box.add_child(_slot_row(it, true))
		while shown < cap:
			shown += 1
			_slots_box.add_child(_slot_row({}, false))


func _slot_row(item: Dictionary, filled: bool) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(300, 54)
	b.add_theme_font_size_override("font_size", 13)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if not filled:
		b.text = "  —— 空 ——"
		b.disabled = true
		b.add_theme_color_override("font_color_disabled", Color(0.45, 0.48, 0.53))
		return b
	var tier := clampi(int(item.get("tier", 0)), 0, 3)
	b.text = "  %s · %s" % [str(item.get("name", "?")), str(item.get("desc", ""))]
	b.add_theme_color_override("font_color", TIER_COLORS[tier])
	b.tooltip_text = "点击卸下"
	var uid := int(item.get("uid", -1))
	b.pressed.connect(func(): unequip_requested.emit(uid))
	return b


## 背包网格：底格画在 _draw 里，物品按钮按 core 给的 layout 摆（占多格的按钮也一起变大）
func _rebuild_bag(snap: Dictionary) -> void:
	for c in _bag_area.get_children():
		_bag_area.remove_child(c)
		c.queue_free()
	# 背包扩容会加行：格子按可用高度自适应，5×6 也不会溢出面板
	var rows := maxi(1, int(snap.get("bag_rows", 2)))
	_cell = clampf((BAG_AREA.y - GAP * float(rows - 1)) / float(rows), 42.0, CELL)
	var items: Array = snap.get("items", [])
	if items.is_empty():
		var empty := Label.new()
		empty.text = "背包是空的。精良箱或商店「普通词条」可以获得。"
		empty.position = Vector2(4, 10)
		empty.add_theme_font_size_override("font_size", 14)
		empty.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
		_bag_area.add_child(empty)
		return
	var by_uid := {}
	for it in items:
		by_uid[int(it["uid"])] = it
	for entry in snap.get("bag_layout", []):
		var uid := int(entry["uid"])
		var item: Dictionary = by_uid.get(uid, {})
		if item.is_empty():
			continue
		var w := int(entry["w"])
		var h := int(entry["h"])
		var b := _item_button(item)
		b.position = Vector2(int(entry["x"]) * (_cell + GAP), int(entry["y"]) * (_cell + GAP))
		b.size = Vector2(_cell * w + GAP * (w - 1), _cell * h + GAP * (h - 1))
		b.custom_minimum_size = b.size
		_bag_area.add_child(b)


func _item_button(item: Dictionary) -> Button:
	var b := Button.new()
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.add_theme_font_size_override("font_size", 11)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var equipped := bool(item.get("equipped", false))
	var is_res := bool(item.get("is_resource", false))
	var kind_name := str(item["kind"])
	if is_res:
		kind_name = String(InventorySystem.RESOURCE_LABELS.get(kind_name, "资源"))
	else:
		kind_name = "配件" if kind_name == "attachment" else "词条"
	var tier := clampi(int(item.get("tier", 0)), 0, 3)
	var fp_x := 1
	if is_res:
		# 资源堆：显示数量，右键丢掉
		b.text = "%s\n×%d" % [str(item.get("name", "资源")), int(item.get("count", 0))]
		b.add_theme_color_override("font_color", Color(0.80, 0.72, 0.45))
		b.tooltip_text = "资源堆叠（占 1 格）· 右键丢弃"
	else:
		b.text = "%s%s\n%s · %s\n卖 %d" % [
			"◆" if equipped else "", str(item.get("name", "?")), kind_name,
			str(item.get("desc", "")), int(item.get("sell", 0))]
		b.add_theme_color_override("font_color", TIER_COLORS[tier])
		b.tooltip_text = "左键 %s · 右键卖出（%d 格）" % ["卸下" if equipped else "装备", fp_x]
	var uid := int(item.get("uid", -1))
	b.pressed.connect(func():
		if is_res:
			return
		if equipped:
			unequip_requested.emit(uid)
		else:
			equip_requested.emit(uid))
	b.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
			if is_res:
				drop_requested.emit(uid)     # 资源不可卖，右键=丢弃整堆
			else:
				sell_requested.emit(uid))
	return b


func _rebuild_stats(snap: Dictionary) -> void:
	var mods: Dictionary = snap.get("mods", {})
	var parts: PackedStringArray = []
	for key in ["dmg", "rate", "spread", "repair", "speed"]:
		var v := float(mods.get(key, 1.0))
		parts.append("%s ×%.2f" % [str(STAT_LABELS.get(key, key)), v])
	_stats.text = "属性合计：" + "   ".join(parts)


func _draw() -> void:
	if not visible:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.04, 0.82))
	# 背包底格（物品按钮画在它上面）
	if _bag_area != null:
		var cols := int(_snap.get("bag_cols", 5))
		var rows := int(_snap.get("bag_rows", 2))
		for y in range(rows):
			for x in range(cols):
				var rect := Rect2(_bag_area.position + Vector2(x * (_cell + GAP), y * (_cell + GAP)),
					Vector2(_cell, _cell))
				draw_rect(rect, Color(0.07, 0.08, 0.10, 0.95))
				draw_rect(rect, Color(1, 1, 1, 0.07), false, 1.0)