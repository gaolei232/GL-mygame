extends SceneTree
## 一次性探针：确认 Godot 侧能加载守卫 GLB（PackedScene），含蒙皮网格 + 四态动画，非回退胶囊。
func _init() -> void:
	var path := "res://art/assets/models/guard/mdl_guard_normal_v1.glb"
	print("PROBE exists=", ResourceLoader.exists(path))
	var packed := load(path) as PackedScene
	print("PROBE packed_null=", packed == null)
	if packed != null:
		var inst := packed.instantiate() as Node3D
		var meshes := inst.find_children("*", "MeshInstance3D", true, false)
		var skinned := 0
		for mi in meshes:
			if (mi as MeshInstance3D).skin != null:
				skinned += 1
		var ap := inst.find_child("AnimationPlayer", true, false) as AnimationPlayer
		var anims: Array = []
		if ap != null:
			for a in ap.get_animation_list():
				anims.append(String(a))
		print("PROBE meshes=", meshes.size(), " skinned=", skinned)
		print("PROBE has_anim_player=", ap != null)
		print("PROBE anims=", anims)
		var arm := inst.find_child("Skeleton3D", true, false)
		print("PROBE has_skeleton=", arm != null)
	quit(0)
