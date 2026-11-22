extends SceneTree

const DT := 1.0 / 60.0
var checks := 0
var failures := 0
var cfg: ConfigDB

func _init() -> void:
	cfg = ConfigDB.new()
	if not cfg.load_all():
		printerr("CONFIG_FAIL ", cfg.errors)
		quit(1)
		return
	_test_catalog_and_purchase()
	_test_equip_and_persistence()
	_test_weapon_attacks()
	print("WEAPON_SHOP checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 2)

func _test_catalog_and_purchase() -> void:
	var sim := Sim.new(cfg)
	sim.new_run(100)
	sim.request("start_run")
	sim.request("return_city")
	sim.state.wave_index = 3
	EconomySystem.roll_shop(sim.state, cfg)
	InventorySystem.set_total(sim.state, "coin", 10000)
	InventorySystem.set_total(sim.state, "metal", 100)
	var ids := ["light_crossbow", "longsword", "rifle", "pistol", "rpg"]
	for id in ids:
		var index := _shop_index(sim.state.shop_stock, id)
		_ok(index >= 0, "catalog " + id)
		if index < 0:
			continue
		_ok(EconomySystem.buy(sim.state, cfg, sim.bus, index), "buy " + id)
		_ok(sim.state.player.owned_weapons.has(id), "permanent ownership " + id)
	_ok(sim.state.player.slots.size() == 2, "two weapon slots retained")
	_ok(sim.state.player.slots.has("rpg"), "last purchase replaces a slot rather than trapping")

func _test_equip_and_persistence() -> void:
	var sim := Sim.new(cfg)
	sim.new_run(101)
	sim.request("start_run")
	sim.state.wave_index = 3
	sim.request("return_city")
	InventorySystem.set_total(sim.state, "coin", 5000)
	InventorySystem.set_total(sim.state, "metal", 100)
	for id in ["light_crossbow", "longsword", "rifle", "pistol", "rpg"]:
		var index := _shop_index(sim.state.shop_stock, id)
		if index >= 0:
			EconomySystem.buy(sim.state, cfg, sim.bus, index)
	_ok(EconomySystem.equip_owned(sim.state, "rifle", 0, sim.bus), "equip owned rifle into slot 1")
	_ok(EconomySystem.equip_owned(sim.state, "longsword", 1, sim.bus), "equip longsword into slot 2")
	_ok(sim.state.player.slots == ["rifle", "longsword"], "equip mapping")
	_ok(EconomySystem.equip_owned(sim.state, "rpg", 0, sim.bus), "swap owned weapon into occupied slot")
	_ok(sim.state.player.owned_weapons.size() >= 6, "owned set retains swapped weapons")
	var save := SaveSystem.capture(sim.state)
	var restored := GameState.new()
	_ok(SaveSystem.restore(restored, cfg, EventBus.new(), save), "new save restores")
	_ok(restored.player.owned_weapons.has("rifle") and restored.player.owned_weapons.has("rpg"), "ownership persisted")
	var legacy := save.duplicate(true)
	legacy["player"].erase("owned_weapons")
	var legacy_state := GameState.new()
	_ok(SaveSystem.restore(legacy_state, cfg, EventBus.new(), legacy), "legacy save restores")
	_ok(legacy_state.player.owned_weapons.has("rpg"), "legacy ownership inferred from slots")

func _test_weapon_attacks() -> void:
	for id in ["crossbow", "rifle", "pistol", "rpg"]:
		var sim := Sim.new(cfg)
		sim.new_run(102)
		sim.request("start_run")
		sim.state.player.owned_weapons.append(id)
		EconomySystem.equip_weapon(sim.state, id, 0)
		var enemy := EnemyFactory.spawn(sim.state, cfg, "walker", sim.state.player.pos + Vector2(0, -8))
		var hp := enemy.hp
		var ammo := sim.state.ammo
		var shot_kind := ""
		for i in range(30):
			sim.step(DT, {"aim": enemy.pos, "fire": true, "switch_to": -1})
			for event in sim.drain_events():
				if str(event["type"]) == EventBus.SHOT_FIRED:
					shot_kind = str(event["data"].get("kind", ""))
		_ok(shot_kind == id, "ranged event kind " + id)
		_ok(enemy.hp < hp and sim.state.ammo < ammo, "ranged damage/shared ammo " + id)
	var melee := Sim.new(cfg)
	melee.new_run(103)
	melee.request("start_run")
	melee.state.player.owned_weapons.append("longsword")
	EconomySystem.equip_weapon(melee.state, "longsword", 0)
	var target := EnemyFactory.spawn(melee.state, cfg, "walker", melee.state.player.pos + Vector2(0, -2))
	var before := target.hp
	melee.step(DT, {"aim": target.pos, "fire": true, "switch_to": -1})
	var kind := ""
	for event in melee.drain_events():
		if str(event["type"]) == EventBus.SHOT_FIRED:
			kind = str(event["data"].get("kind", ""))
	_ok(kind == "longsword", "longsword event kind")
	_ok(target.hp < before, "longsword melee damages target")
	_ok(melee.state.player.slots.has("longsword"), "longsword uses a gun shortcut; knife remains slot 4")

func _shop_index(stock: Array, id: String) -> int:
	for index in range(stock.size()):
		if str(stock[index].get("key", "")) == id:
			return index
	return -1

func _ok(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("PASS ", label)
	else:
		failures += 1
		printerr("FAIL ", label)
