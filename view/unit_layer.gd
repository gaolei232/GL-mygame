class_name UnitLayer
extends Node3D
## 表现层 · 单位：玩家、敌人、箱子。
## 所有位置来自 snapshot 的逻辑坐标 (x, z)，这里只做 y 轴抬升与朝向插值。

const KIND_COLORS := {
	"walker": Color(0.45, 0.62, 0.42),
	"runner": Color(0.85, 0.78, 0.35),
	"bomber": Color(0.90, 0.45, 0.25),
	"brute": Color(0.75, 0.25, 0.28),
}

## 命中闪白时长与死亡过渡时长（P0-3）。死亡不能用「这帧就不见了」——
## 敌人瞬间消失读不出「打死了」，只会像穿帮。
const FLASH_TIME := 0.09
const DEATH_TIME := 0.30

## 玩家手里的弩：正式风格化弩（Blender 生成，弩身+上弦弩箭，冷青箭头）。
## 原点在握把、出弹端 +Y（Blender）→ Godot -Z（与主角同向），故持握朝向用 atan2(-dir)。
const CROSSBOW_SCENE := "res://art/assets/models/weapon/mdl_weapon_crossbow_v1.glb"
const WEAPON_MODELS := {
	"crossbow": [CROSSBOW_SCENE, 0.8], "light_crossbow": [CROSSBOW_SCENE, 0.62],
	"pistol": ["res://art/assets/models/weapon/mdl_weapon_pistol_v1.glb", 0.95],
	"rifle": ["res://art/assets/models/weapon/mdl_weapon_rifle_v1.glb", 0.85],
	"rpg": ["res://art/assets/models/weapon/mdl_weapon_rpg_v1.glb", 0.72],
	"longsword": ["res://art/assets/models/weapon/mdl_weapon_longsword_v1.glb", 0.8],
}
const WEAPON_ACTIONS := {
	"pistol": "fire_pistol", "rifle": "fire_rifle", "rpg": "fire_rpg",
	"longsword": "slash_sword", "knife": "slash_knife",
}

## 玩家本体：Blender 生成的低模（骨骼 + idle/walk/run/fire/hit/roll 六条动画）
## 面向 Godot -Z（Blender +Y），原点在脚底；缺资产时回退胶囊。
const HERO_SCENE := "res://art/assets/models/char/mdl_char_hero_normal_v3.glb"
const HERO_FALLBACK_SCENE := "res://art/assets/models/char/mdl_char_hero_normal_v1.glb"
const HERO_ANIM_IDLE := "idle"
const HERO_ANIM_WALK := "walk"
const HERO_ANIM_RUN := "run"
const HERO_ANIM_FIRE := "fire"
const HERO_ANIM_HIT := "hit"
const HERO_ANIM_ROLL := "roll"
const HERO_HIT_TIME := 0.42
## 走/跑的动画基准速度（m/s）：速度低于 WALK_MAX 播 walk，高于则播 run。
## 游戏基础移速 7.0（sprint_mult 2.0 → 冲刺 14.0），故 7 附近应由 run 承担。
const HERO_WALK_ANIM_MPS := 3.2
const HERO_RUN_ANIM_MPS := 7.0
const HERO_WALK_MAX_MPS := 4.6
## 翻滚：逻辑侧 4.2m / 0.28s（balance.roll），GLB 内 roll 动画 9 帧 = 0.333s
const HERO_ROLL_ANIM_TIME := 0.333
const HERO_ROLL_LOGIC_TIME := 0.28
## 转身速度（1/s）：移动时略快，静止瞄准时慢一些，读起来更稳
const HERO_TURN_MOVE := 16.0
const HERO_TURN_AIM := 13.0

## 敌人低模（Blender 生成，原点脚底、面向 -Z 时需要朝移动方向转）
## v2 = 带骨骼与动画（idle/walk/attack，bomber 另有 fuse）
const ENEMY_SCENES := {
	"walker": "res://art/assets/models/mon/mdl_mon_walker_normal_v3.glb",
	"runner": "res://art/assets/models/mon/mdl_mon_runner_normal_v3.glb",
	"bomber": "res://art/assets/models/mon/mdl_mon_bomber_normal_v3.glb",
	"brute": "res://art/assets/models/mon/mdl_mon_brute_normal_v3.glb",
}
const ENEMY_ANIM_IDLE := "idle"
const ENEMY_ANIM_WALK := "walk"
const ENEMY_ANIM_ATTACK := "attack"
const ENEMY_ANIM_HIT := "hit"
const ENEMY_ANIM_FUSE := "fuse"
const ENEMY_HIT_TIME := 0.50
## 攻击动作时长（Godot 侧实测 GLB：28/20/24/44 帧 ÷ 24fps）
const ENEMY_ATTACK_TIME := {"walker": 1.17, "runner": 0.83, "bomber": 1.00, "brute": 1.83}
## 行走动画的基准移动速度（TSV speed × 0.10：walker 4 / runner 9.2 / bomber 5.5 / brute 2）
const ENEMY_WALK_ANIM_MPS := {"walker": 2.4, "runner": 6.0, "bomber": 3.0, "brute": 1.6}

## 守卫低模（Blender 生成的制式步兵）：带骨骼 + idle/intercept/attack/return 四态动画，
## 与 GuardSystem 四态一一对应。面向 Godot -Z（Blender +Y），原点在脚底；缺资产时回退胶囊。
const GUARD_SCENE := "res://art/assets/models/guard/mdl_guard_normal_v1.glb"
const GUARD_ANIM_IDLE := "idle"
const GUARD_ANIM_INTERCEPT := "intercept"
const GUARD_ANIM_ATTACK := "attack"
const GUARD_ANIM_RETURN := "return"

var player_body: Node3D            # 玩家容器（原点在脚底）
var player_model: Node3D           # GLB 模型或兜底胶囊
var player_anim: AnimationPlayer
var player_skeleton: Skeleton3D
var player_hand_bone := -1
var player_meshes: Array = []
var player_hurt_mat: StandardMaterial3D
var player_aim := Vector2(0, 1)
var player_yaw := 0.0
var player_last_pos := Vector2.ZERO
var player_speed := 0.0
var player_fire_left := 0.0
var player_hit_left := 0.0
var player_hurt_prev := false
var player_roll_prev := false
var hero_uses_glb := false
var player_aim_bar: MeshInstance3D
var weapon_node: Node3D
var enemy_views: Dictionary = {}
var enemy_meshes: Dictionary = {}      # id -> Array[MeshInstance3D]（给闪白做 material_override）
var enemy_anims: Dictionary = {}       # id -> AnimationPlayer（GLB 动画）
var enemy_flash_mat: StandardMaterial3D
var enemy_fx: Dictionary = {}      # id -> {flash: float, dying: float}
var guard_views: Dictionary = {}
var guard_last_pos: Dictionary = {}   # id → 上一帧位置，用于朝移动方向转身
var box_views: Dictionary = {}
var box_lid_t: Dictionary = {}   # 箱子索引 → 开盖进度 0..1（开盖动画用）
var mat_cache: Dictionary = {}


## 中弹闪白：由 app 层在 ENEMY_HIT 时调用（事件在这一帧 sync 之后才 drain）
func flash_enemy(id: int, seconds: float = FLASH_TIME) -> void:
	var fx: Dictionary = enemy_fx.get(id, {})
	if float(fx.get("dying", 0.0)) > 0.0:
		return                     # 已经进入死亡过渡，闪白没有意义
	fx["flash"] = maxf(float(fx.get("flash", 0.0)), seconds)
	fx["dying"] = float(fx.get("dying", 0.0))
	enemy_fx[id] = fx


func setup() -> void:
	player_body = Node3D.new()
	player_body.name = "Player"
	add_child(player_body)
	player_hurt_mat = StandardMaterial3D.new()
	player_hurt_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	player_hurt_mat.albedo_color = Color(1.0, 0.32, 0.26)
	enemy_flash_mat = StandardMaterial3D.new()
	enemy_flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	enemy_flash_mat.albedo_color = Color(1.0, 0.92, 0.86)
	player_model = _make_player_model()
	player_body.add_child(player_model)
	player_aim_bar = _make_box(Vector3(0.10, 0.02, 1.4), Color(0.95, 0.88, 0.70))
	add_child(player_aim_bar)
	weapon_node = Node3D.new()
	weapon_node.name = "HeldWeapon"
	add_child(weapon_node)
	_select_weapon_model("crossbow")


## 实例化主角 GLB（骨骼 + 动画）；失败则退回旧胶囊，保证 headless 测试与缺资产场景可跑
func _make_player_model() -> Node3D:
	var path := HERO_SCENE if ResourceLoader.exists(HERO_SCENE) else HERO_FALLBACK_SCENE
	if not ResourceLoader.exists(path):
		return _make_fallback_player()
	var packed := load(path) as PackedScene
	if packed == null:
		return _make_fallback_player()
	var inst := packed.instantiate() as Node3D
	hero_uses_glb = true
	player_skeleton = inst.find_child("Skeleton3D", true, false) as Skeleton3D
	if player_skeleton != null:
		player_hand_bone = player_skeleton.find_bone("hand.R")
		if player_hand_bone < 0:
			player_hand_bone = player_skeleton.find_bone("hand.L")

	player_anim = inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
	for mi in inst.find_children("*", "MeshInstance3D", true, false):
		player_meshes.append(mi)
	if player_anim != null:
		_setup_player_anims(player_anim)
	if player_anim != null and player_anim.has_animation(HERO_ANIM_IDLE):
		player_anim.play(HERO_ANIM_IDLE)
	return inst


## 循环策略：idle/walk/run 循环；fire/hit/roll 单次（否则翻滚会一直滚）
func _setup_player_anims(ap: AnimationPlayer) -> void:
	for anim_name in [HERO_ANIM_IDLE, HERO_ANIM_WALK, HERO_ANIM_RUN]:
		if ap.has_animation(anim_name):
			ap.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR
	for anim_name in [HERO_ANIM_FIRE, HERO_ANIM_HIT, HERO_ANIM_ROLL] + WEAPON_ACTIONS.values():
		if ap.has_animation(anim_name):
			ap.get_animation(anim_name).loop_mode = Animation.LOOP_NONE


func _make_fallback_player() -> Node3D:
	push_warning("[view] 主角 GLB 缺失，回退胶囊：" + HERO_SCENE)
	var cap := _make_capsule(0.42, 1.8, Color(0.35, 0.62, 0.95))
	cap.position = Vector3(0, 0.9, 0)
	return cap


## 由实际攻击事件触发，翻滚和受击优先。
func play_player_fire(kind: String = "crossbow", interval: float = 0.0) -> void:
	if player_roll_prev or player_hit_left > 0.0 or player_anim == null:
		return
	var clip: String = WEAPON_ACTIONS.get(kind, HERO_ANIM_FIRE)
	if not player_anim.has_animation(clip):
		clip = HERO_ANIM_FIRE
	if not player_anim.has_animation(clip):
		return
	var length := player_anim.get_animation(clip).length
	player_fire_left = minf(length, interval) if interval > 0.0 else length
	player_anim.stop(true)
	player_anim.speed_scale = 1.0
	player_anim.play(clip, 0.0, length / maxf(player_fire_left, 0.01))


func _play_player_anim(anim_name: String, blend := 0.12) -> void:
	if player_anim == null or not player_anim.has_animation(anim_name):
		return
	if player_anim.current_animation == anim_name:
		return
	player_anim.play(anim_name, blend)


func _select_weapon_model(kind: String) -> void:
	if weapon_node.get_meta("kind", "") == kind:
		return
	weapon_node.set_meta("kind", kind)
	for child in weapon_node.get_children():
		weapon_node.remove_child(child)
		child.queue_free()
	var spec: Array = WEAPON_MODELS.get(kind, [])
	if spec.is_empty() or not ResourceLoader.exists(spec[0]):
		return
	var packed := load(spec[0]) as PackedScene
	if packed != null:
		var inst := packed.instantiate() as Node3D
		inst.scale = Vector3.ONE * float(spec[1])
		weapon_node.add_child(inst)


func sync(snap: Dictionary, delta: float) -> void:
	_sync_player(snap, delta)
	_sync_enemies(snap, delta)
	_sync_guards(snap, delta)
	_sync_boxes(snap, delta)


func _sync_player(snap: Dictionary, delta: float) -> void:
	var p: Dictionary = snap["player"]
	var pos: Vector2 = p["pos"]
	# 模型原点在脚底：容器直接落在逻辑坐标的地面高度上（旧胶囊是中心 +0.9）
	var target := Vector3(pos.x, TerrainHeight.at(pos.x, pos.y), pos.y)
	player_body.position = player_body.position.lerp(target, clampf(delta * 16.0, 0.0, 1.0))
	player_body.visible = bool(p["alive"])

	# 移动速度与移动方向（给 walk/run 调播放速率；翻滚时不算走）
	var moved := pos - player_last_pos
	player_speed = moved.length() / maxf(delta, 0.0001)
	player_last_pos = pos
	var move_dir := moved.normalized() if moved.length() > 0.0001 else Vector2.ZERO

	var aim: Vector2 = p["aim"]
	var to_aim := aim - pos
	if to_aim.length() > 0.1:
		player_aim = to_aim.normalized()

	# 朝向优先级：翻滚方向 > 移动方向（运动时要面向运动方向）> 瞄准方向（站定时对准准星）
	# 模型面向 -Z，故 yaw = atan2(-dir.x, -dir.y)。
	var rolling := bool(p.get("rolling", false))
	var face_dir := Vector2.ZERO
	var turn_rate := HERO_TURN_AIM
	if rolling:
		face_dir = p.get("roll_dir", Vector2.ZERO)
		turn_rate = HERO_TURN_MOVE * 2.0
	elif player_speed > 0.6:
		face_dir = move_dir
		turn_rate = HERO_TURN_MOVE
	else:
		face_dir = player_aim
	if face_dir.length() > 0.01:
		var target_yaw := atan2(-face_dir.x, -face_dir.y)
		player_yaw = lerp_angle(player_yaw, target_yaw, clampf(delta * turn_rate, 0.0, 1.0))
	player_body.rotation.y = player_yaw

	# 翻滚现在由真动画（roll：360° 前滚 + 逐帧贴地）表现，不再用前倾/压扁冒充；
	# 这里只把可能残留的旧姿态平滑归零。
	player_model.rotation.x = lerpf(player_model.rotation.x, 0.0, clampf(delta * 18.0, 0.0, 1.0))
	if not player_model.scale.is_equal_approx(Vector3.ONE):
		player_model.scale = player_model.scale.lerp(Vector3.ONE, clampf(delta * 16.0, 0.0, 1.0))

	# 翻滚上升沿播一次 roll（动画 0.333s / 逻辑 0.28s，按比例加速，滚完正好结束）
	if rolling != player_roll_prev:
		player_roll_prev = rolling
		if rolling:
			player_fire_left = 0.0
			player_hit_left = 0.0
		if rolling and hero_uses_glb and player_anim != null and player_anim.has_animation(HERO_ANIM_ROLL):
			player_anim.stop()
			player_anim.play(HERO_ANIM_ROLL)

	# 受击：整模泛红 + 播一次受击动作
	var hurt := float(p["hurt_flash"]) > 0.0
	if hurt != player_hurt_prev:
		player_hurt_prev = hurt
		for mi in player_meshes:
			(mi as MeshInstance3D).material_override = player_hurt_mat if hurt else null
		if not hero_uses_glb and player_model is MeshInstance3D:
			# 兜底胶囊沿用旧的染色表现
			_set_color(player_model, Color(0.95, 0.35, 0.30) if hurt else Color(0.35, 0.62, 0.95))
		if hurt and hero_uses_glb and not rolling:
			player_hit_left = HERO_HIT_TIME
			player_fire_left = 0.0
			if player_anim != null and player_anim.has_animation(HERO_ANIM_HIT):
				player_anim.stop()
				player_anim.play(HERO_ANIM_HIT)

	# 动画状态机：翻滚 > 受击 > 开火 > 跑 > 走 > 待机
	player_fire_left = maxf(0.0, player_fire_left - delta)
	player_hit_left = maxf(0.0, player_hit_left - delta)
	if hero_uses_glb and player_anim != null:
		if rolling:
			# 翻滚动作的播放速率 = 动画时长 / 逻辑时长，保证滚动与位移同步结束
			player_anim.speed_scale = HERO_ROLL_ANIM_TIME / HERO_ROLL_LOGIC_TIME
		elif player_hit_left > 0.0:
			player_anim.speed_scale = 1.0
		elif player_fire_left > 0.0:
			player_anim.speed_scale = 1.0
		elif player_speed > HERO_WALK_MAX_MPS:
			_play_player_anim(HERO_ANIM_RUN)
			player_anim.speed_scale = clampf(player_speed / HERO_RUN_ANIM_MPS, 0.7, 2.0)
		elif player_speed > 0.5:
			_play_player_anim(HERO_ANIM_WALK)
			player_anim.speed_scale = clampf(player_speed / HERO_WALK_ANIM_MPS, 0.7, 1.6)
		else:
			_play_player_anim(HERO_ANIM_IDLE)
			player_anim.speed_scale = 1.0

	# 瞄准条：贴地显示，避免从胸口横穿模型（方向足够可读，又挡住不乱）
	if to_aim.length() > 0.1:
		player_aim_bar.position = player_body.position + Vector3(0, 0.06, 0)
		player_aim_bar.rotation.y = atan2(to_aim.x, to_aim.y)
	player_aim_bar.visible = bool(p["alive"])

	var slot := int(p.get("active_slot", 0))
	var slots: Array = p.get("slots", [])
	var kind := str(slots[slot]) if slot >= 0 and slot < mini(slots.size(), 2) else ""
	_select_weapon_model(kind)
	weapon_node.visible = bool(p["alive"]) and not rolling and weapon_node.get_child_count() > 0
	if weapon_node.visible:
		var attacking := player_fire_left > 0.0
		var weapon_yaw := player_yaw if player_speed > 0.6 and not attacking else atan2(-player_aim.x, -player_aim.y)
		var swing := 0.0
		if attacking and kind == "longsword":
			var progress := player_anim.current_animation_position / maxf(player_anim.current_animation_length, 0.01)
			swing = lerpf(-1.15, 1.25, smoothstep(0.0, 0.65, progress)) * (1.0 - smoothstep(0.65, 1.0, progress))
		var dir := Vector2(-sin(weapon_yaw), -cos(weapon_yaw))
		weapon_yaw += swing
		if hero_uses_glb and player_skeleton != null and player_hand_bone >= 0 and is_inside_tree():
			# 位置跟右手骨（开火抬手时一起动）
			var hand_pose := player_skeleton.get_bone_global_pose(player_hand_bone)
			var hand_world := player_skeleton.global_transform * hand_pose.origin
			weapon_node.global_position = hand_world \
				+ Vector3(dir.x, 0.0, dir.y) * 0.10 + Vector3(0, 0.04, 0)
			weapon_node.rotation = Vector3(0, weapon_yaw, 0)
		else:
			var hold := pos + dir * 0.30 + Vector2(dir.y, -dir.x) * 0.16
			weapon_node.position = Vector3(hold.x, 0.98 + TerrainHeight.at(hold.x, hold.y), hold.y)
			weapon_node.rotation.y = weapon_yaw


func _make_enemy_view(kind: String, id: int) -> Node3D:
	var container := Node3D.new()
	container.name = "Enemy_%s_%d" % [kind, id]
	var scene_path := str(ENEMY_SCENES.get(kind, ""))
	var meshes: Array = []
	if scene_path != "" and ResourceLoader.exists(scene_path):
		var packed := load(scene_path) as PackedScene
		if packed != null:
			var inst := packed.instantiate() as Node3D
			for mi in inst.find_children("*", "MeshInstance3D", true, false):
				meshes.append(mi)
			var ap := inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
			if ap != null:
				enemy_anims[id] = ap
				_setup_enemy_anims(ap)
				if ap.has_animation(ENEMY_ANIM_IDLE):
					ap.play(ENEMY_ANIM_IDLE)
			container.add_child(inst)
	if meshes.is_empty():
		# 缺资产兜底：旧胶囊，容器原点在脚底
		var radius := 0.45
		var height := 1.8
		if kind == "brute":
			radius = 0.9
			height = 3.2
		elif kind == "runner":
			height = 1.7
		var cap := _make_capsule(radius, height, KIND_COLORS.get(kind, Color.GRAY))
		cap.position = Vector3(0, height * 0.5, 0)
		container.add_child(cap)
		meshes.append(cap)
	container.set_meta("meshes", meshes)
	return container


## 导入的 GLB 动画默认不循环：idle/walk/fuse 设成循环，attack 保持单次
func _setup_enemy_anims(ap: AnimationPlayer) -> void:
	for anim_name in [ENEMY_ANIM_IDLE, ENEMY_ANIM_WALK, ENEMY_ANIM_FUSE, ENEMY_ANIM_HIT]:
		if ap.has_animation(anim_name):
			ap.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR


func _play_enemy_anim(id: int, anim_name: String, blend := 0.10) -> void:
	var ap: AnimationPlayer = enemy_anims.get(id)
	if ap == null or not ap.has_animation(anim_name):
		return
	if ap.current_animation == anim_name and ap.is_playing():
		return
	ap.play(anim_name, blend)


## 由 app 层在 ENEMY_HIT 时调用：播放一次受击后仰动作
func play_enemy_hit(id: int) -> void:
	var fx: Dictionary = enemy_fx.get(id, {})
	if fx.is_empty() or float(fx.get("dying", 0.0)) > 0.0:
		return
	fx["hit"] = ENEMY_HIT_TIME
	fx["atk"] = 0.0
	enemy_fx[id] = fx
	var ap: AnimationPlayer = enemy_anims.get(id)
	if ap != null and ap.has_animation(ENEMY_ANIM_HIT):
		ap.stop()
		ap.play(ENEMY_ANIM_HIT)


## 由 app 层在 ENEMY_ATTACK 时调用：播一次攻击动作（砸墙/拆建筑/打水晶共用一个事件）
func play_enemy_attack(id: int) -> void:
	var fx: Dictionary = enemy_fx.get(id, {})
	if fx.is_empty() or float(fx.get("dying", 0.0)) > 0.0:
		return
	var kind := str(fx.get("kind", "walker"))
	fx["atk"] = float(ENEMY_ATTACK_TIME.get(kind, 1.0))
	enemy_fx[id] = fx
	var ap: AnimationPlayer = enemy_anims.get(id)
	if ap != null and ap.has_animation(ENEMY_ANIM_ATTACK):
		ap.stop()
		ap.play(ENEMY_ANIM_ATTACK)


func _sync_enemies(snap: Dictionary, delta: float) -> void:
	var seen := {}
	for e in snap["enemies"]:
		var id := int(e["id"])
		seen[id] = true
		var kind := str(e["kind"])
		var view: Node3D = enemy_views.get(id)
		if view == null:
			view = _make_enemy_view(kind, id)
			add_child(view)
			enemy_views[id] = view
			enemy_meshes[id] = view.get_meta("meshes", [])
			enemy_fx[id] = {"flash": 0.0, "dying": 0.0, "last": e["pos"], "atk": 0.0, "hit": 0.0,
				"kind": kind, "base": KIND_COLORS.get(kind, Color.GRAY)}
		var fx: Dictionary = enemy_fx.get(id, {"flash": 0.0, "dying": 0.0, "last": e["pos"],
			"atk": 0.0, "hit": 0.0, "kind": kind})
		fx["flash"] = maxf(0.0, float(fx["flash"]) - delta)
		fx["hit"] = maxf(0.0, float(fx.get("hit", 0.0)) - delta)
		fx["atk"] = maxf(0.0, float(fx.get("atk", 0.0)) - delta)
		var pos: Vector2 = e["pos"]
		var last: Vector2 = fx.get("last", pos)
		var moved := pos - last
		fx["last"] = pos
		enemy_fx[id] = fx
		var spd := moved.length() / maxf(delta, 0.0001)
		var target := Vector3(pos.x, TerrainHeight.at(pos.x, pos.y), pos.y)
		view.position = view.position.lerp(target, clampf(delta * 14.0, 0.0, 1.0))
		# 朝向移动方向（模型面向 -Z）
		if moved.length() > 0.004:
			view.rotation.y = lerp_angle(view.rotation.y,
				atan2(-moved.x, -moved.y), clampf(delta * 8.0, 0.0, 1.0))
		# 受击闪白：材质覆盖（胶囊/GLB 同一套）
		var flash := float(fx["flash"])
		for mi in enemy_meshes.get(id, []):
			(mi as MeshInstance3D).material_override = enemy_flash_mat if flash > 0.0 else null
		# 动画状态机：引信 > 攻击 > 走 > 待机
		var ap: AnimationPlayer = enemy_anims.get(id)
		var fusing := kind == "bomber" and float(e.get("fuse", 0.0)) > 0.0
		if ap != null:
			if fusing and ap.has_animation(ENEMY_ANIM_FUSE):
				_play_enemy_anim(id, ENEMY_ANIM_FUSE, 0.15)
				ap.speed_scale = 1.0
			elif float(fx.get("hit", 0.0)) > 0.0:
				pass      # 受击动作播完前不切走
			elif float(fx.get("atk", 0.0)) > 0.0:
				pass      # 攻击动作播完前不切走（逻辑上此时也停着不走）
			elif spd > 0.15:
				_play_enemy_anim(id, ENEMY_ANIM_WALK)
				ap.speed_scale = clampf(spd / float(ENEMY_WALK_ANIM_MPS.get(kind, 2.0)), 0.7, 2.2)
			else:
				_play_enemy_anim(id, ENEMY_ANIM_IDLE)
				ap.speed_scale = 1.0
		# 自爆兵引信期胀缩：有 fuse 动画时交给动作，只有兜底胶囊才靠缩放提示
		if fusing and ap == null:
			var pulse := 1.0 + 0.05 * sin(Time.get_ticks_msec() * 0.02)
			view.scale = Vector3(pulse, pulse, pulse)
		elif not fusing:
			view.scale = view.scale.lerp(Vector3.ONE, clampf(delta * 20.0, 0.0, 1.0))

	# 快照里消失 = 这一帧死了：压扁 + 下沉 0.3s 再移除（P0-3）
	for id in enemy_views.keys():
		var view: Node3D = enemy_views[id]
		if seen.has(id):
			continue
		var fx: Dictionary = enemy_fx.get(id, {"flash": 0.0, "dying": 0.0})
		if float(fx["dying"]) <= 0.0:
			fx["dying"] = DEATH_TIME
		fx["dying"] = float(fx["dying"]) - delta
		var k := clampf(float(fx["dying"]) / DEATH_TIME, 0.0, 1.0)
		enemy_fx[id] = fx
		view.scale = Vector3(1.0 + (1.0 - k) * 0.35, maxf(0.02, k), 1.0 + (1.0 - k) * 0.35)
		view.position.y -= (1.0 - k) * delta * 1.2
		if float(fx["dying"]) <= 0.0:
			view.queue_free()
			enemy_views.erase(id)
			enemy_fx.erase(id)
			enemy_meshes.erase(id)
			enemy_anims.erase(id)


## 守卫视图（Blender 低模制式步兵）：按守卫状态播 idle/intercept/attack/return 四态动画、
## 朝移动方向转身、血量比例压暗表示受伤；缺资产回退胶囊。
func _sync_guards(snap: Dictionary, delta: float) -> void:
	var seen := {}
	for g in snap["guards"]:
		var id := int(g["id"])
		seen[id] = true
		var view: Node3D = guard_views.get(id)
		if view == null:
			view = _make_guard_view(id)
			add_child(view)
			guard_views[id] = view
		view.visible = bool(g["alive"])
		if not bool(g["alive"]):
			continue
		var pos: Vector2 = g["pos"]
		# 原点在脚底：直接落到地形高度
		var target := Vector3(pos.x, TerrainHeight.at(pos.x, pos.y), pos.y)
		view.position = view.position.lerp(target, clampf(delta * 14.0, 0.0, 1.0))
		# 朝移动方向转身（模型面向 -Z）
		var last: Vector2 = guard_last_pos.get(id, pos)
		var moved := pos - last
		guard_last_pos[id] = pos
		if moved.length() > 0.004:
			view.rotation.y = lerp_angle(view.rotation.y,
				atan2(-moved.x, -moved.y), clampf(delta * 8.0, 0.0, 1.0))
		# 血量比例压暗
		var ratio := float(g["hp"]) / maxf(1.0, float(g["max_hp"]))
		_set_guard_damage(view.get_meta("meshes", []), ratio)
		# 按状态播四态动画
		_play_guard_anim(view.get_meta("anim", null), str(g.get("state", "idle")))
	for id in guard_views.keys():
		if not seen.has(id):
			guard_views[id].queue_free()
			guard_views.erase(id)
			guard_last_pos.erase(id)


## 实例化守卫 GLB（骨骼 + 动画）；失败则回退胶囊。原点在脚底。
func _make_guard_view(id: int) -> Node3D:
	var container := Node3D.new()
	container.name = "Guard_%d" % id
	var meshes: Array = []
	var ap: AnimationPlayer = null
	if ResourceLoader.exists(GUARD_SCENE):
		var packed := load(GUARD_SCENE) as PackedScene
		if packed != null:
			var inst := packed.instantiate() as Node3D
			for mi in inst.find_children("*", "MeshInstance3D", true, false):
				_dup_mats(mi)          # 逐实例复制材质，供逐守卫血量压暗（共享材质会一起变暗）
				meshes.append(mi)
			ap = inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
			if ap != null:
				_setup_guard_anims(ap)
				if ap.has_animation(GUARD_ANIM_IDLE):
					ap.play(GUARD_ANIM_IDLE)
			container.add_child(inst)
	if meshes.is_empty():
		push_warning("[view] 守卫 GLB 缺失，回退胶囊：" + GUARD_SCENE)
		var cap := _make_capsule(0.38, 1.7, Color(0.62, 0.78, 0.92))
		cap.position = Vector3(0, 0.85, 0)   # 容器原点在脚底，胶囊中心抬半高
		container.add_child(cap)
		meshes.append(cap)
	container.set_meta("meshes", meshes)
	container.set_meta("anim", ap)
	return container


## 复制每槽材质为实例私有（否则共享材质会让所有守卫一起压暗）
func _dup_mats(mi: MeshInstance3D) -> void:
	if mi.mesh == null:
		return
	for s in range(mi.mesh.get_surface_count()):
		var base := mi.get_active_material(s)
		if base != null:
			mi.set_surface_override_material(s, base.duplicate())


## 导入的守卫动画默认不循环：四态全部设为循环（attack 是挥砍循环，契合 1s 攻击间隔）
func _setup_guard_anims(ap: AnimationPlayer) -> void:
	for anim_name in [GUARD_ANIM_IDLE, GUARD_ANIM_INTERCEPT, GUARD_ANIM_ATTACK, GUARD_ANIM_RETURN]:
		if ap.has_animation(anim_name):
			ap.get_animation(anim_name).loop_mode = Animation.LOOP_LINEAR


## 守卫状态 → 动画（idle/intercept/attack/return 一一对应）
func _play_guard_anim(ap: AnimationPlayer, state: String, blend := 0.12) -> void:
	if ap == null:
		return
	var anim := GUARD_ANIM_IDLE
	match state:
		"intercept":
			anim = GUARD_ANIM_INTERCEPT
		"attack":
			anim = GUARD_ANIM_ATTACK
		"return":
			anim = GUARD_ANIM_RETURN
	if not ap.has_animation(anim):
		return
	if ap.current_animation == anim and ap.is_playing():
		return
	ap.play(anim, blend)


## 逐守卫血量比例压暗（满血 1.0 → 空血 0.40）；用 meta 记原始 albedo 避免累乘变黑
func _set_guard_damage(meshes: Array, ratio: float) -> void:
	var dim := clampf(0.40 + 0.60 * ratio, 0.0, 1.0)
	for m in meshes:
		var mi := m as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for s in range(mi.mesh.get_surface_count()):
			var mat := mi.get_active_material(s)
			if mat is StandardMaterial3D:
				var sm := mat as StandardMaterial3D
				var base: Color
				if sm.has_meta("base_albedo"):
					base = sm.get_meta("base_albedo")
				else:
					base = sm.albedo_color
					sm.set_meta("base_albedo", base)
				sm.albedo_color = Color(base.r * dim, base.g * dim, base.b * dim, base.a)


## 宝箱低模（Blender 生成）：tier → GLB。原点在箱底，模型正面朝 -Z。
## v4 = 拆出 GEO_Chest_Lid* 盖子网格，供开盖动画使用。
const LOOT_BOX_SCENES := {
	"common": "res://art/assets/models/prop/mdl_loot_box_wood_v4.glb",
	"refined": "res://art/assets/models/prop/mdl_loot_box_metal_v4.glb",
	"military": "res://art/assets/models/prop/mdl_loot_box_military_v4.glb",
}
const BOX_PLACEHOLDER_SIZE := Vector3(0.9, 0.9, 0.9)
## 开盖：盖子绕后缘铰链翻开 110°（三档共用同一壳体尺寸）
const LID_PIVOT_POS := Vector3(0, 0.64, 0.39)   # 后缘（模型正面朝 -Z，背面 +Z）
const LID_OPEN_RAD := 1.92                      # 110°
const LID_ANIM_SPEED := 3.2                     # 开/合盖插值速度（1/s）


func _make_loot_box_view(tier: String, index: int) -> Node3D:
	var container := Node3D.new()
	container.name = "LootBox_%s_%d" % [tier, index]
	var scene_path := str(LOOT_BOX_SCENES.get(tier, ""))
	var meshes: Array = []
	var lid_pivot: Node3D = null
	if scene_path != "" and ResourceLoader.exists(scene_path):
		var packed := load(scene_path) as PackedScene
		if packed != null:
			var inst := packed.instantiate() as Node3D
			container.add_child(inst)
			for mi in inst.find_children("*", "MeshInstance3D", true, false):
				meshes.append(mi)
			# 盖子网格（GEO_Chest_Lid*）挂到后缘铰链枢轴上，供开盖动画旋转
			var lid_meshes: Array = []
			for mi in meshes:
				if (mi as Node).name.begins_with("GEO_Chest_Lid"):
					lid_meshes.append(mi)
			if not lid_meshes.is_empty():
				lid_pivot = Node3D.new()
				lid_pivot.name = "LidPivot"
				lid_pivot.position = LID_PIVOT_POS
				container.add_child(lid_pivot)
				for mi in lid_meshes:
					var lm := mi as Node3D
					var pos := lm.position - LID_PIVOT_POS
					lm.get_parent().remove_child(lm)
					lm.owner = null          # reparent 到枢轴前清 owner，避免 owner 不一致警告
					lid_pivot.add_child(lm)
					lm.position = pos
	if meshes.is_empty():
		# 缺资产兜底：旧方块，原点在脚底（y 补偿半高）
		var color := Color(0.75, 0.62, 0.30) if tier == "common" else Color(0.55, 0.78, 0.95)
		var box_mesh := _make_box(BOX_PLACEHOLDER_SIZE, color)
		box_mesh.position = Vector3(0, BOX_PLACEHOLDER_SIZE.y * 0.5, 0)
		container.add_child(box_mesh)
		meshes.append(box_mesh)
	container.set_meta("meshes", meshes)
	container.set_meta("lid_pivot", lid_pivot)
	return container


func _sync_boxes(snap: Dictionary, delta: float) -> void:
	var seen := {}
	var searching := int(snap.get("searching_box", -1))
	for i in range(snap["loot"].size()):
		var box: Dictionary = snap["loot"][i]
		var tier := str(box.get("tier", "common"))
		var view: Node3D = box_views.get(i)
		if view == null:
			view = _make_loot_box_view(tier, i)
			add_child(view)
			box_views[i] = view
			# 每个箱子的朝向做确定性扰动，避免一排箱子像复制粘贴
			view.rotation.y = float((i * 37) % 360) * 0.01745
		var pos: Vector2 = box["pos"]
		# 模型原点在箱底：直接落到地形高度
		view.position = Vector3(pos.x, TerrainHeight.at(pos.x, pos.y), pos.y)
		# 2026-11-15：已开箱但还有物资没拿的箱子要继续显示——
		# 否则人一走开箱子就"消失"，玩家没法回来取剩下的东西。
		var pending := false
		for it in box.get("items", []):
			if not bool(it.get("taken", false)):
				pending = true
				break
		if not pending:
			var bonus: Variant = box.get("bonus", {})
			pending = bonus is Dictionary and not (bonus as Dictionary).is_empty()
		var opened := bool(box["opened"])
		view.visible = (not opened) or pending
		# 开盖动画：搜索中或已打开 → 盖子绕后缘铰链翻开（目标 1，速度 3.2/s）
		var lid_pivot: Node3D = view.get_meta("lid_pivot", null)
		if lid_pivot != null:
			var target := 1.0 if (opened or searching == i) else 0.0
			box_lid_t[i] = move_toward(float(box_lid_t.get(i, 0.0)), target,
				delta * LID_ANIM_SPEED)
			lid_pivot.rotation.x = float(box_lid_t[i]) * LID_OPEN_RAD
		elif opened:
			# 兜底方块没有盖子：退回旧的压小表现
			view.scale = view.scale.lerp(Vector3(0.86, 0.86, 0.86), 0.35)
		seen[i] = true
	for i in box_views.keys():
		if not seen.has(i):
			box_views[i].queue_free()
			box_views.erase(i)
			box_lid_t.erase(i)


func _make_capsule(radius: float, height: float, color: Color) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.7
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _make_box(size: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _set_color(node: MeshInstance3D, color: Color) -> void:
	var mat: StandardMaterial3D = node.mesh.material
	mat.albedo_color = color
