class_name OddsPanel
extends Control
## 概率公示（P1-6，合规项）：稀有度掉落权重 / 倍数 / 售价 + 词条池。
## 只渲染 app 传进来的数据（数据源 data/items.json），面板里不写死任何数值。

signal closed

const PANEL_SIZE := Vector2(780, 566)
const COL := Color(0.92, 0.94, 0.97)
const DIM := Color(0.62, 0.66, 0.72)
const GOLD := Color(0.95, 0.80, 0.42)

var _skin := HudSkin.new()
var _panel: Panel
var _title: Label
var _content: VBoxContainer
var _close: Button


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
	_title.text = "概 率 公 示"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 28)
	_title.add_theme_color_override("font_color", GOLD)
	add_child(_title)

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 6)
	add_child(_content)

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
	_title.position = origin + Vector2(0, 16)
	_title.size = Vector2(PANEL_SIZE.x, 34)
	_content.position = origin + Vector2(28, 62)
	_content.size = Vector2(PANEL_SIZE.x - 56, PANEL_SIZE.y - 128)
	_close.position = origin + Vector2((PANEL_SIZE.x - 200) * 0.5, PANEL_SIZE.y - 60)
	_close.size = Vector2(200, 44)


## data = {tiers: [{name, mult, sell, color}], waves: ["第 1 波"...], weights: [[..],..], items: [...]}
func open(data: Dictionary) -> void:
	_rebuild(data)
	visible = true


func close() -> void:
	visible = false


func _rebuild(data: Dictionary) -> void:
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()

	_add_note("数据源：data/items.json（与掉落逻辑共用同一份配置，改表即生效）。百分比为该档在本波的抽取占比。")

	_add_section("稀有度掉落概率")
	var waves: Array = data.get("waves", [])
	var tiers: Array = data.get("tiers", [])
	var weights: Array = data.get("weights", [])
	var grid := _grid(4 + waves.size())
	_cell(grid, "稀有度", 130, GOLD, HORIZONTAL_ALIGNMENT_LEFT)
	_cell(grid, "数值", 78, DIM)
	_cell(grid, "售价", 78, DIM)
	for w in waves:
		_cell(grid, str(w), 92, DIM)
	for i in range(tiers.size()):
		var row: Dictionary = tiers[i]
		_cell(grid, str(row.get("name", "?")), 130, Color(str(row.get("color", "#ffffff"))),
			HORIZONTAL_ALIGNMENT_LEFT)
		_cell(grid, "×%.2f" % float(row.get("mult", 1.0)), 78, COL)
		_cell(grid, "%d 金" % int(row.get("sell", 0)), 78, COL)
		for wi in range(waves.size()):
			var row_weights: Array = weights[wi] if wi < weights.size() else []
			var pct := _pct(row_weights, i)
			_cell(grid, pct, 92, COL if pct != "0%" else DIM)

	_add_section("词条池（数值 = 基础值 × 稀有度倍率）")
	var items: Array = data.get("items", [])
	var grid2 := _grid(4)
	_cell(grid2, "名称", 150, GOLD, HORIZONTAL_ALIGNMENT_LEFT)
	_cell(grid2, "类型", 100, DIM, HORIZONTAL_ALIGNMENT_LEFT)
	_cell(grid2, "效果", 300, DIM, HORIZONTAL_ALIGNMENT_LEFT)
	_cell(grid2, "基础值", 120, DIM)
	for it in items:
		var kind := "配件" if str(it.get("kind", "")) == "attachment" else "词条"
		var base := float(it.get("base", 0.0))
		_cell(grid2, str(it.get("name", "?")), 150, COL, HORIZONTAL_ALIGNMENT_LEFT)
		_cell(grid2, kind, 100, COL, HORIZONTAL_ALIGNMENT_LEFT)
		_cell(grid2, str(it.get("desc", "")), 300, COL, HORIZONTAL_ALIGNMENT_LEFT)
		_cell(grid2, "%s%.0f%%" % ["+" if base >= 0.0 else "-", absf(base) * 100.0], 120, COL)

	_add_note("获取途径：精良箱清空驻守后必掉 1 件；商店「普通词条」购买 1 件；稀有度按上表权重随机。")
	_add_note("箱子档位不是随机：搜集期每 3 个箱子固定 1 个精良箱（位置规则），因此不涉及概率。")
	_add_note("同类词条相加、配件相乘：final =（1 + Σ词条）× Π（1 + 配件）。")


func _pct(row_weights: Array, tier: int) -> String:
	var total := 0
	for w in row_weights:
		total += int(w)
	if total <= 0 or tier >= row_weights.size():
		return "0%"
	return "%d%%" % int(round(float(int(row_weights[tier])) / float(total) * 100.0))


func _grid(columns: int) -> GridContainer:
	var g := GridContainer.new()
	g.columns = columns
	g.add_theme_constant_override("h_separation", 8)
	g.add_theme_constant_override("v_separation", 4)
	_content.add_child(g)
	return g


func _cell(grid: GridContainer, text: String, width: int, color: Color,
		align: int = HORIZONTAL_ALIGNMENT_CENTER) -> void:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(width, 24)
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", color)
	grid.add_child(l)


func _add_section(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", GOLD)
	_content.add_child(l)


func _add_note(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(PANEL_SIZE.x - 56, 0)
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", DIM)
	_content.add_child(l)


func _draw() -> void:
	if visible:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.03, 0.04, 0.86))