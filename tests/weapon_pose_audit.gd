extends SceneTree
## Headless checks; pass -- --capture in windowed mode to render representative poses.

const CLIPS := {"crossbow": "fire", "light_crossbow": "fire", "pistol": "fire_pistol",
	"rifle": "fire_rifle", "rpg": "fire_rpg", "longsword": "slash_sword"}

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var capture := "--capture" in OS.get_cmdline_user_args()
	var units := UnitLayer.new()
	root.add_child(units)
	units.setup()
	if units.player_anim == null:
		push_error("Hero animation player missing")
		quit(1)
		return
	if capture:
		var env := WorldEnvironment.new()
		env.environment = Environment.new()
		env.environment.background_mode = Environment.BG_COLOR
		env.environment.background_color = Color(0.08, 0.10, 0.13)
		env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.environment.ambient_light_color = Color(0.63, 0.70, 0.80)
		env.environment.ambient_light_energy = 0.7
		root.add_child(env)
		var sun := DirectionalLight3D.new()
		sun.rotation_degrees = Vector3(-45, -28, 0)
		sun.light_energy = 1.5
		root.add_child(sun)
		var cam := Camera3D.new()
		cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		cam.size = 2.35
		root.add_child(cam)
		cam.look_at_from_position(Vector3(2.6, 2.15, -3.4), Vector3(0, 0.9, -0.1))
		cam.make_current()
	var failures := 0
	for kind: String in CLIPS:
		var p := {"alive": true, "aim": Vector2(0, -4), "pos": Vector2.ZERO,
			"hurt_flash": 0.0, "slots": [kind, ""], "active_slot": 0, "rolling": false}
		var snap := {"player": p, "enemies": [], "guards": [], "loot": []}
		units.sync(snap, 0.1)
		units.play_player_fire(kind, 0.25)
		var ap := units.player_anim
		if not units.weapon_node.visible or ap.current_animation != CLIPS[kind] or ap.get_playing_speed() < 1.0:
			push_error("Incorrect model or action for %s (%s)" % [kind, ap.current_animation])
			failures += 1
			continue
		if capture:
			for sample in range(3):
				ap.seek(ap.current_animation_length * [0.12, 0.32, 0.60][sample], true)
				units.sync(snap, 0.0)
				units.player_aim_bar.hide()
				await RenderingServer.frame_post_draw
				var path := "res://art/review/char/weapon_%s_%d.png" % [kind, sample]
				if root.get_texture().get_image().save_png(path) != OK:
					failures += 1
					push_error("Cannot write %s" % path)
	print("WEAPON_POSE_AUDIT failures=", failures)
	quit(1 if failures else 0)
