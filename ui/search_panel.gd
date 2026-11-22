class_name SearchPanel
extends Control
## 搜索式开箱界面（2026-11-09）：4×4 网格，逐格扫描，物资扫到才显现。
## 只读 snapshot；网格/进度/显现状态全部来自 core，UI 不做任何判定。

const CELL := 74.0
const GAP := 6.0
const PAD := 16.0
const HEAD := 34.0
const FOOT := 30.0

## 双击拾取（2026-11-15）：扫描完只是「显现」，物资要玩家双击才进背包。
## item_index >= 0 = 网格里的物资；-1 = 精良箱附带词条（画在底部条上）。
signal loot_take_requested(box_index: int, item_index: int)

const TIER_COLORS := [
	Color(0.81, 0.83, 0.86), Color(0.50, 0.79, 0.54), Color(0.42, 0.68, 0.94),
	Color(0.72, 0.55, 0.94), Color(0.88, 0.70, 0.30),
]
const TIER_NUMERALS := ["Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ"]
const KIND_ICONS := {"coin": "icon_coin", "brick": "icon_brick", "metal": "icon_metal", "ammo": "icon_ammo"}
const KIND_NAMES := {"coin": "金币", "brick": "砖块", "metal": "金属", "ammo": "弹药"}
const BOX_NAMES := {"common": "普通物资箱", "refined": "精良物资箱"}

var _skin := HudSkin.new()
var _font: Font
var _box: Dictionary = {}
var _cols := 4
var _rows := 4
var _active := false
var _index_cache := -1


func _ready() -> void:
	# 面板要接收双击，所以必须是 STOP；只在可见时生效（见 sync_from）
	mouse_filter = Control.MOUSE_FILTER_STOP
	_font = ThemeDB.fallback_font
	visible = false
	get_viewport().size_changed.connect(_layout)


func _gui_input(event: InputEvent) -> void:
	if not _active:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if not mb.double_click:
		return
	var idx := _item_at(mb.position)
	if idx == -2:
		return
	var box_index := _box_index()
	if box_index < 0:
		return
	loot_take_requested.emit(box_index, idx)
	accept_event()


## 点到哪件已显现、未拾取的物资；返回 item 下标，-1 = 精良箱词条，-2 = 没点到
func _item_at(p: Vector2) -> int:
	var items: Array = _box.get("items", [])
	var bonus: Variant = _box.get("bonus", {})
	if bonus is Dictionary and not (bonus as Dictionary).is_empty():
		if _bonus_rect().has_point(p):
			return -1
	var origin := Vector2(PAD, PAD + HEAD)
	for i in range(items.size()):
		var it: Dictionary = items[i]
		if not bool(it.get("revealed", false)) or bool(it.get("taken", false)):
			continue
		var w := int(it.get("w", 1))
		var h := int(it.get("h", 1))
		var rect := Rect2(
			origin + Vector2(int(it.get("x", 0)) * (CELL + GAP), int(it.get("y", 0)) * (CELL + GAP)),
			Vector2(CELL * w + GAP * (w - 1), CELL * h + GAP * (h - 1)))
		if rect.has_point(p):
			return i
	return -2


func _bonus_rect() -> Rect2:
	return Rect2(Vector2(PAD, size.y - FOOT - 22.0), Vector2(size.x - PAD * 2.0, 22.0))


func _box_index() -> int:
	return _index_cache


func _layout() -> void:
	var w := CELL * float(_cols) + GAP * float(_cols - 1) + PAD * 2.0
	var h := CELL * float(_rows) + GAP * float(_rows - 1) + HEAD + FOOT + PAD * 2.0
	size = Vector2(w, h)
	position = Vector2(get_viewport_rect().size.x - w - 24.0,
		(get_viewport_rect().size.y - h) * 0.5 - 20.0)


## 每帧由 app 调用：searching_box >= 0 时展示对应箱子
func sync_from(snap: Dictionary) -> void:
	var idx := int(snap.get("searching_box", -1))
	var loot: Array = snap.get("loot", [])
	# 已搜完的箱子不再处于 searching 状态，但玩家可能还想拾取：
	# 这时用 near_box 让面板继续保持打开。
	if idx < 0:
		var nb := int(snap.get("near_box", -1))
		if nb >= 0 and nb < loot.size() and bool(loot[nb].get("opened", false)):
			idx = nb
	if idx < 0 or idx >= loot.size():
		if _active:
			_active = false
			_box = {}
			visible = false
		return
	if not _active:
		_active = true
		visible = true
		_layout()
	_box = loot[idx]
	_index_cache = idx
	queue_redraw()


func _draw() -> void:
	if not _active:
		return
	var box_tier := str(_box.get("tier", "common"))
	var cells: Array = _box.get("cells", [])
	var items: Array = _box.get("items", [])
	var revealed: Array = _box.get("revealed", [])
	var pointer := int(_box.get("pointer", 0))
	var left := float(_box.get("cell_left", 0.0))
	var total := float(_box.get("cell_total", 0.0))

	# 面板底
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.06, 0.08, 0.9))
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.10), false, 1.0)

	# 标题：箱名 + 已扫/总数
	var title: String = str(BOX_NAMES.get(box_tier, "物资箱"))
	var scanned := 0
	for r in revealed:
		if bool(r):
			scanned += 1
	if bool(_box.get("opened", false)):
		title += "（已搜完 · 双击拾取）"
	_text(Vector2(PAD, PAD + 16), title, 16, Color(0.95, 0.80, 0.42))
	_text(Vector2(size.x - PAD - 78, PAD + 16), "%d / %d" % [scanned, cells.size()], 14,
		Color(0.62, 0.66, 0.72))

	var origin := Vector2(PAD, PAD + HEAD)

	# 1) 底格：未扫暗格 / 已扫空格的叉；属于「未显现多格物品」的格子留白，交给第 2 步
	for i in range(cells.size()):
		var col := i % _cols
		var row := i / _cols
		var rect := Rect2(origin + Vector2(col * (CELL + GAP), row * (CELL + GAP)), Vector2(CELL, CELL))
		var idx := int(cells[i])
		var is_revealed := i < revealed.size() and bool(revealed[i])
		if is_revealed:
			if idx < 0:
				var c := rect.position + rect.size * 0.5
				var r := 10.0
				draw_rect(rect, Color(0.09, 0.10, 0.13, 0.95))
				draw_line(c + Vector2(-r, -r), c + Vector2(r, r), Color(1, 1, 1, 0.16), 2.0)
				draw_line(c + Vector2(r, -r), c + Vector2(-r, r), Color(1, 1, 1, 0.16), 2.0)
			continue
		if idx >= 0 and idx < items.size() and not bool(items[idx].get("revealed", false)):
			if int(items[idx].get("w", 1)) * int(items[idx].get("h", 1)) > 1:
				continue            # 多格物品：画成虚线占位块，提前暴露形状
		draw_rect(rect, Color(0.07, 0.08, 0.10, 0.98))
		draw_rect(rect, Color(1, 1, 1, 0.06), false, 1.0)

	# 2) 未显现的多格物品：暗块 + 虚线描边（只露形状，不露等级与数量）
	for it in items:
		if bool(it.get("revealed", false)):
			continue
		var w := int(it.get("w", 1))
		var h := int(it.get("h", 1))
		if w * h <= 1:
			continue
		var rect := Rect2(
			origin + Vector2(int(it.get("x", 0)) * (CELL + GAP), int(it.get("y", 0)) * (CELL + GAP)),
			Vector2(CELL * w + GAP * (w - 1), CELL * h + GAP * (h - 1)))
		draw_rect(rect, Color(0.11, 0.12, 0.15, 0.95))
		_dashed_rect(rect, Color(0.58, 0.62, 0.70, 0.55))

	# 3) 当前格的扫描进度（画在占位块之上，否则会被盖住）
	if pointer < cells.size() and not bool(revealed[pointer]):
		var pcol := pointer % _cols
		var prow := pointer / _cols
		var prect := Rect2(origin + Vector2(pcol * (CELL + GAP), prow * (CELL + GAP)), Vector2(CELL, CELL))
		var ratio := 0.0
		if total > 0.0:
			ratio = clampf(1.0 - left / total, 0.0, 1.0)
		draw_rect(Rect2(prect.position + Vector2(4, prect.size.y - 8),
			Vector2((prect.size.x - 8) * ratio, 4)), Color(0.95, 0.80, 0.42, 0.95))
		draw_rect(prect, Color(0.95, 0.80, 0.42, 0.7), false, 2.0)

	# 4) 已显现的物品按真实占位画成一整块（1×1 / 1×2 / 2×1 / 2×2）
	for it in items:
		if not bool(it.get("revealed", false)):
			continue
		var w := int(it.get("w", 1))
		var h := int(it.get("h", 1))
		var rect := Rect2(
			origin + Vector2(int(it.get("x", 0)) * (CELL + GAP), int(it.get("y", 0)) * (CELL + GAP)),
			Vector2(CELL * w + GAP * (w - 1), CELL * h + GAP * (h - 1)))
		var tier := clampi(int(it.get("tier", 1)), 1, 5)
		var color: Color = TIER_COLORS[tier - 1]
		var taken := bool(it.get("taken", false))
		draw_rect(rect, Color(0.06, 0.07, 0.09, 0.98) if taken else Color(0.10, 0.11, 0.14, 0.98))
		draw_rect(rect, color if not taken else Color(color, 0.30), false, 2.0)
		if taken:
			draw_line(rect.position + Vector2(12, rect.size.y * 0.5),
				rect.position + rect.size - Vector2(12, rect.size.y * 0.5),
				Color(1, 1, 1, 0.18), 2.0)
			continue
		var icon_key := str(KIND_ICONS.get(str(it.get("kind", "")), ""))
		var icon_size := minf(38.0, rect.size.x - 20.0)
		if icon_key != "":
			_skin.draw_icon(self, icon_key, Rect2(rect.position + Vector2(14, 12), Vector2(icon_size, icon_size)))
		_text(rect.position + Vector2(10, rect.size.y - 10), "+%d" % int(it.get("amount", 0)), 14, color)
		_text(rect.position + Vector2(rect.size.x - 26, 22), TIER_NUMERALS[tier - 1], 15, color)

	# 底注
	var bonus: Variant = _box.get("bonus", {})
	if bonus is Dictionary and not (bonus as Dictionary).is_empty():
		var br := _bonus_rect()
		draw_rect(br, Color(0.30, 0.36, 0.20, 0.85))
		draw_rect(br, Color(0.62, 0.80, 0.45, 0.9), false, 1.0)
		_text(br.position + Vector2(8, 15), "词条待拾取 · 双击拿走", 12, Color(0.86, 0.94, 0.78))
	_text(Vector2(PAD, size.y - 10), "搜完双击拾取 · 拿不拿由你决定 · 格子越大越稀有", 12,
		Color(0.78, 0.82, 0.88))


## 虚线描边（CanvasItem 没有 dash 原语，四边自己切段）
func _dashed_rect(rect: Rect2, color: Color, dash: float = 9.0, gap: float = 6.0) -> void:
	var pts := [
		[rect.position, rect.position + Vector2(rect.size.x, 0)],
		[rect.position + Vector2(rect.size.x, 0), rect.position + rect.size],
		[rect.position + rect.size, rect.position + Vector2(0, rect.size.y)],
		[rect.position + Vector2(0, rect.size.y), rect.position],
	]
	for seg in pts:
		var a: Vector2 = seg[0]
		var b: Vector2 = seg[1]
		var len := a.distance_to(b)
		if len <= 0.0:
			continue
		var dir := (b - a) / len
		var t := 0.0
		while t < len:
			var t2 := minf(t + dash, len)
			draw_line(a + dir * t, a + dir * t2, color, 2.0)
			t = t2 + gap


func _text(pos: Vector2, text: String, size_px: int, color: Color) -> void:
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px, color)