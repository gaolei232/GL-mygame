extends Node
## 概率公示探针：核对数据源、面板文本、开关与 Esc。

var app: Node
var frames := 0
var texts: Array = []
var checks := 0
var failures := 0


func _ready() -> void:
	app = get_tree().root.find_child("GameApp", true, false)


func _ok(condition: bool, name: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  PASS ", name)
	else:
		failures += 1
		printerr("  FAIL ", name, "  ", detail)


func _process(_dt: float) -> void:
	frames += 1
	match frames:
		4:
			var data: Dictionary = app._odds_data()
			var weights: Array = data["weights"]
			_ok(data["tiers"].size() == 4, "稀有度 4 档来自 items.json")
			_ok(weights[0] == [70, 30, 0, 0] and weights[1] == [70, 30, 0, 0],
				"第 1–2 波权重 70/30/0/0", str(weights[0]))
			_ok(weights[2] == [35, 45, 20, 0] and weights[3] == [35, 45, 20, 0],
				"第 3–4 波权重 35/45/20/0", str(weights[2]))
			_ok(weights[4] == [0, 30, 50, 20], "第 5 波权重 0/30/50/20", str(weights[4]))
			_ok(data["items"].size() == 7, "词条池 7 条", "%d" % data["items"].size())
		6:
			app._open_odds()
			_ok(app.odds.visible, "概率公示可打开")
			texts.clear()
			_collect(app.odds._content)
			_ok(texts.has("70%"), "面板画出 70% 这一档")
			_ok(texts.has("第 5 波"), "面板有第 5 波列")
			_ok(texts.has("锋芒") and texts.has("巧匠"), "面板列出词条池名称")
			_ok(texts.has("×2.10") and texts.has("240 金"), "面板列出传说倍率与售价")
		7:
			_ok(not app.menu.input_enabled, "覆盖层打开时主菜单键盘被禁用")
		8:
			app._close_odds()
			_ok(not app.odds.visible, "关闭按钮生效")
		10:
			app._open_odds()
			_press(KEY_ESCAPE)
		12:
			_ok(not app.odds.visible, "Esc 关闭概率公示")
			_ok(app.menu.input_enabled, "关闭后主菜单键盘恢复")
			print("CHECKS %d, FAILURES %d" % [checks, failures])
			print("ODDS_SMOKE %s" % ("PASS" if failures == 0 else "FAIL"))
			get_tree().quit(0 if failures == 0 else 2)


func _collect(node: Node) -> void:
	if node is Label:
		texts.append((node as Label).text)
	for c in node.get_children():
		_collect(c)


func _press(code: int) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.physical_keycode = code
		ev.keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)