extends SceneTree
## 敌人动画接入验收（Godot 侧）：
## - 4 个 v2 GLB 都能实例化出 AnimationPlayer + Skeleton3D
## - 动画名齐（idle/walk/attack，bomber 另有 fuse），时长与 24fps 导出对得上
## - UnitLayer 能按快照播 walk/idle，收到 ENEMY_ATTACK 时切 attack
## 用法：godot --headless --path . --script res://tests/enemy_anim_probe.gd

const ENEMY_SCENES := {
	"walker": "res://art/assets/models/mon/mdl_mon_walker_normal_v3.glb",
	"runner": "res://art/assets/models/mon/mdl_mon_runner_normal_v3.glb",
	"bomber": "res://art/assets/models/mon/mdl_mon_bomber_normal_v3.glb",
	"brute": "res://art/assets/models/mon/mdl_mon_brute_normal_v3.glb",
}
const EXPECTED := {"walker": 4, "runner": 4, "bomber": 5, "brute": 4}
const FRAMES := {"walker": 28, "runner": 20, "bomber": 24, "brute": 44}

var fails := 0
var checks := 0


func _ok(cond: bool, label: String, detail: String = "") -> void:
	checks += 1
	if cond:
		print("OK   ", label, (" | " + detail) if detail != "" else "")
	else:
		fails += 1
		print("FAIL ", label, (" | " + detail) if detail != "" else "")


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame

	# 1) 资产层：动画/骨骼
	for kind in ENEMY_SCENES.keys():
		var path: String = ENEMY_SCENES[kind]
		_ok(ResourceLoader.exists(path), "%s GLB 存在" % kind)
		var inst: Node3D = (load(path) as PackedScene).instantiate()
		root.add_child(inst)
		await process_frame
		var ap := inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
		var sk := inst.find_child("Skeleton3D", true, false) as Skeleton3D
		_ok(ap != null, "%s 有 AnimationPlayer" % kind)
		_ok(sk != null and sk.get_bone_count() == 20,
			"%s 骨骼数=20" % kind, "got=%d" % (sk.get_bone_count() if sk != null else -1))
		if ap != null:
			var names := ap.get_animation_list()
			var expected := ["attack", "idle", "walk"]
			if kind == "bomber":
				expected.append("fuse")
			for a in expected:
				_ok(names.has(a), "%s 动画 %s" % [kind, a], str(names))
			var hit := ap.get_animation("hit")
			_ok(hit != null and absf(hit.length - (11.0 / 24.0)) < 0.06,
				"%s hit 时长≈0.46s" % kind, "got=%.3f" % (hit.length if hit != null else -1.0))
			var atk := ap.get_animation("attack")
			var secs := float(FRAMES[kind] - 1) / 24.0
			_ok(absf(atk.length - secs) < 0.06, "%s attack 时长≈%.2fs" % [kind, secs],
				"got=%.3f" % atk.length)
		inst.queue_free()

	# 2) 表现层：UnitLayer 状态机（走 → 待机 → 攻击）
	var units := UnitLayer.new()
	root.add_child(units)
	units.setup()
	var snap := {
		"player": {"pos": Vector2.ZERO, "aim": Vector2(0, 1), "alive": true,
			"rolling": false, "hurt_flash": 0.0, "slots": ["crossbow", ""],
			"active_slot": 0},
		"enemies": [{"id": 11, "kind": "walker", "pos": Vector2(0, -6), "fuse": 0.0,
			"phase": "walk"}],
		"guards": [], "loot": [],
	}
	units.sync(snap, 0.016)
	await process_frame
	var vis := units.enemy_views.get(11) as Node3D
	_ok(vis != null, "UnitLayer 生成敌人视图")
	var ap1: AnimationPlayer = units.enemy_anims.get(11)
	_ok(ap1 != null, "UnitLayer 记住 AnimationPlayer")
	if ap1 != null:
		print("UNIT_ANIM first=", ap1.current_animation)
		_ok(ap1.current_animation == "idle", "静止时播 idle", ap1.current_animation)

	# 移动 → walk
	snap["enemies"][0]["pos"] = Vector2(0, -5.4)
	units.sync(snap, 0.5)
	await process_frame
	if ap1 != null:
		print("UNIT_ANIM moving=", ap1.current_animation)
		_ok(ap1.current_animation == "walk", "移动时播 walk", ap1.current_animation)

	# 攻击事件 → attack
	units.play_enemy_attack(11)
	await process_frame
	if ap1 != null:
		print("UNIT_ANIM attack=", ap1.current_animation)
		_ok(ap1.current_animation == "attack", "ENEMY_ATTACK 时播 attack", ap1.current_animation)

	# 受击事件 → hit
	units.play_enemy_hit(11)
	await process_frame
	if ap1 != null:
		print("UNIT_ANIM hit=", ap1.current_animation)
		_ok(ap1.current_animation == "hit", "受击时播 hit", ap1.current_animation)

	# 自爆兵引信 → fuse
	snap["enemies"] = [{"id": 12, "kind": "bomber", "pos": Vector2(2, -6), "fuse": 2.0,
		"phase": "fuse"}]
	units.sync(snap, 0.016)
	await process_frame
	var ap2: AnimationPlayer = units.enemy_anims.get(12)
	_ok(ap2 != null, "自爆兵 AnimationPlayer")
	if ap2 != null:
		print("UNIT_ANIM fuse=", ap2.current_animation)
		_ok(ap2.current_animation == "fuse", "引信期播 fuse", ap2.current_animation)

	print("ENEMY_ANIM_PROBE checks=%d fails=%d" % [checks, fails])
	quit(0 if fails == 0 else 1)