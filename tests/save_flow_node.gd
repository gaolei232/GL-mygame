extends Node
## 存档流程探针：真实 main.tscn + 真实 GameApp，只驱动阶段与按钮回调。

const SAVE_PATH := "res://tests/_tmp_save.json"   # 沙箱下 user:// 不可写，测试写到工作区

var app: Node
var frames := 0
var saved_coin := -1
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
		2:
			app.save_path = SAVE_PATH
			app._clear_save()
			_ok(not FileAccess.file_exists(SAVE_PATH), "开局前无存档")
		4:
			app.sim.request("start_run")          # TITLE → SCOUT（应写档）
		8:
			app.sim.request("return_city")        # SCOUT → BUILD（应写档）
		12:
			_ok(FileAccess.file_exists(SAVE_PATH), "进入建设期后自动落盘")
			var data: Dictionary = app._read_save()
			saved_coin = int(data.get("coin", -1))
			_ok(int(data.get("phase", -1)) == GameState.Phase.BUILD, "存档阶段 = 建设期",
				"phase=%d" % int(data.get("phase", -1)))
			_ok(app.menu._continue_btn.visible, "主菜单出现「继续」按钮")
		14:
			InventorySystem.set_total(app.sim.state, "coin", 9999)             # 弄脏当前状态，验证「继续」是读档而非沿用
			app._on_continue()
		18:
			_ok(app.sim.state.phase == GameState.Phase.BUILD, "继续后回到建设期")
			_ok(app.sim.state.coin == saved_coin, "继续后金币来自存档",
				"预期 %d，实际 %d" % [saved_coin, app.sim.state.coin])
			_ok(app.sim.state.enemies.is_empty(), "继续后没有残留敌人")
		20:
			print("CHECKS %d, FAILURES %d" % [checks, failures])
			print("SAVE_FLOW %s" % ("PASS" if failures == 0 else "FAIL"))
			DirAccess.remove_absolute(SAVE_PATH)
			get_tree().quit(0 if failures == 0 else 2)