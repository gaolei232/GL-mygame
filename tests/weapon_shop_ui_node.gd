extends SceneTree

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var cfg := ConfigDB.new()
	if not cfg.load_all():
		printerr("CONFIG_FAIL ", cfg.errors)
		quit(1)
		return
	var hud := Hud.new()
	root.add_child(hud)
	var sim := Sim.new(cfg)
	sim.new_run(404)
	sim.request("start_run")
	sim.request("return_city")
	sim.state.wave_index = 3
	EconomySystem.roll_shop(sim.state, cfg)
	hud.update_snapshot(sim.snapshot())
	var labels: Array[String] = []
	_collect_text(hud, labels)
	for label in ["轻弩", "长剑", "步枪", "手枪", "火箭筒"]:
		_ok(_contains_text(labels, label), "shop label " + label)
	_ok(hud.has_signal("request_equip_weapon"), "equip signal exposed")
	await process_frame
	var scroll := hud._panel_box.get_parent() as ScrollContainer
	_ok(scroll != null and scroll.size.y > 0.0 and scroll.get_rect().end.y <= root.get_visible_rect().size.y,
		"panel content scrolls within viewport")
	print("WEAPON_SHOP_UI checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 2)

func _collect_text(node: Node, out: Array[String]) -> void:
	if node is Button or node is Label:
		out.append(str(node.text))
	for child in node.get_children():
		_collect_text(child, out)

func _contains_text(values: Array[String], needle: String) -> bool:
	for value in values:
		if value.contains(needle):
			return true
	return false

func _ok(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("PASS ", label)
	else:
		failures += 1
		printerr("FAIL ", label)
