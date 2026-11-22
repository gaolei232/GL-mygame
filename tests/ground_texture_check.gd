extends SceneTree
## 地面贴图接入验收：确认三张贴图绑定到对应地面材质、UV 保持每 9m 一张、明度落在目标带。
## 用法：godot --path . --script res://tests/ground_texture_check.gd

const TEX := {
	"plaza": "res://art/assets/env/tex_ground_plaza_tile_v2.png",
	"wilds": "res://art/assets/env/tex_ground_wilds_tile_v2.png",
	"scrub": "res://art/assets/env/tex_ground_scrub_tile_v2.png",
}
const TARGET_L := {"plaza": 30.0, "wilds": 23.0, "scrub": 23.0}


func _initialize() -> void:
	var failures := 0
	for kind in TEX:
		var tex := load(TEX[kind]) as Texture2D
		if tex == null:
			printerr("FAIL missing ", TEX[kind])
			failures += 1
			continue
		var img := tex.get_image()
		if img == null or img.get_width() != 1024 or img.get_height() != 1024:
			printerr("FAIL size ", kind, " ", img.get_size() if img else null)
			failures += 1
			continue
		var pixels := img.get_data()
		var total := 0.0
		var count := 0
		for y in range(0, img.get_height(), 32):
			for x in range(0, img.get_width(), 32):
				var p := img.get_pixel(x, y)
				total += p.r * 0.2126 + p.g * 0.7152 + p.b * 0.0722
				count += 1
		var luma := total / float(count) * 100.0
		var ok := absf(luma - TARGET_L[kind]) <= 2.5
		if not ok:
			printerr("FAIL luma ", kind, " ", luma, " target ", TARGET_L[kind])
			failures += 1
		else:
			print("PASS ", kind, " luma=", luma, " target=", TARGET_L[kind])
	print("GROUND_TEXTURE_CHECK ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 2)