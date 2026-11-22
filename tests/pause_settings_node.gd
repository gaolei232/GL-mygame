extends Node
## 暂停与设置探针：真实 GameApp，只调公开方法与信号回调。

const SAVE_PATH := "res://tests/_tmp_save.json"
const SETTINGS_PATH := "res://tests/_tmp_settings.json"

var app: Node
var frames := 0
var t0 := 0.0
var t1 := 0.0
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
			app.settings_path = SETTINGS_PATH
			app._clear_save()
			_remove(SETTINGS_PATH)
		4:
			app.sim.request("start_run")
		6:
			app.sim.request("return_city")        # BUILD → 顺手写档
		8:
			_ok(FileAccess.file_exists(SAVE_PATH), "建设期已写档（给暂停测试兜底）")
			t0 = app.sim.state.phase_time
			app.set_paused(true)
			_ok(app._paused and app.pause.visible, "Esc 暂停：面板出现、状态置暂停")
		12:
			t1 = app.sim.state.phase_time
			_ok(is_equal_approx(t0, t1), "暂停期间玩法时间不前进",
				"t0=%.3f t1=%.3f" % [t0, t1])
		14:
			app.set_paused(false)
		16:
			_ok(app.sim.state.phase_time > t1 + 0.0001, "恢复后时间继续走",
				"%.3f -> %.3f" % [t1, app.sim.state.phase_time])
		18:
			app._return_to_title()
			_ok(app.sim.state.phase == GameState.Phase.TITLE, "返回主菜单：阶段回 TITLE")
			_ok(FileAccess.file_exists(SAVE_PATH), "返回主菜单不删存档")
			app.set_paused(true)
			_ok(not app._paused, "TITLE 阶段不能暂停")
		20:
			app._on_settings_changed({"volume": 0.25, "fullscreen": false, "quality": 2})
			_ok(FileAccess.file_exists(SETTINGS_PATH), "改设置立刻落盘")
			var data: Dictionary = app._read_settings()
			_ok(is_equal_approx(float(data.get("volume", 0.0)), 0.25) and int(data.get("quality", -1)) == 2,
				"设置读回一致", "volume=%.2f quality=%d" % [float(data.get("volume", 0.0)), int(data.get("quality", -1))])
			var db := AudioServer.get_bus_volume_db(0)
			_ok(absf(db - linear_to_db(0.25)) < 0.5, "音量应用到 Master 总线",
				"db=%.2f 期望 %.2f" % [db, linear_to_db(0.25)])
			_ok(app.get_viewport().msaa_3d == Viewport.MSAA_4X, "画质=高 → MSAA 4×",
				"msaa=%d" % app.get_viewport().msaa_3d)
		22:
			app._on_settings_changed({"volume": 5.0, "fullscreen": true, "quality": 9})
			_ok(is_equal_approx(float(app._settings["volume"]), 1.0) and int(app._settings["quality"]) == 2,
				"越界值被夹回 0..1 / 0..2", "volume=%.2f quality=%d" % [float(app._settings["volume"]), int(app._settings["quality"])])
			app._open_settings()
			_ok(app.settings.visible, "设置面板可打开")
			app._close_settings()
			_ok(not app.settings.visible, "设置面板可关闭")
		26:
			app.sim.request("start_run")          # 回到游戏，验证「真按键」路径
		28:
			t0 = app.sim.state.phase_time
			_press(KEY_ESCAPE)
		30:
			_ok(app._paused, "Esc 真按键：暂停生效")
			_ok(is_equal_approx(t0, app.sim.state.phase_time), "Esc 暂停后时间冻结")
			_press(KEY_ESCAPE)
		34:
			_ok(not app._paused, "再按 Esc：恢复")
			_press(KEY_P)
		36:
			_ok(app._paused, "P 键也能暂停")
			_press(KEY_P)
		38:
			_ok(not app._paused, "再按 P 恢复")
			_remove(SAVE_PATH)
			_remove(SETTINGS_PATH)
			print("CHECKS %d, FAILURES %d" % [checks, failures])
			print("PAUSE_SETTINGS %s" % ("PASS" if failures == 0 else "FAIL"))
			get_tree().quit(0 if failures == 0 else 2)


## 真按键：走 Input.parse_input_event → 视口 → _unhandled_input
func _press(code: int) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.physical_keycode = code
		ev.keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)


func _remove(path: String) -> void:
	var dir := DirAccess.open(path.get_base_dir())
	if dir != null:
		dir.remove(path.get_file())