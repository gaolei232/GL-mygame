class_name TerrainHeight
extends RefCounted
## 地形高度采样（表现层用）。
##
## core 仍然是纯 2D（Vector2(x, z)），玩家可以走全图任意地形；
## 「站多高」只在表现层解决：单位/相机按这里采样到的高度抬升。
## 这样 core 的所有判定（命中、寻敌、事件）一行都不用改。

const HEIGHTS_PATH := "res://art/assets/models/terrain/terrain_map_v001.heights.json"

static var _loaded := false
static var _grid := 0
static var _cell := 1.6
static var _half := 160.0
static var _data := PackedFloat32Array()
static var _min_h := 0.0


static func ensure_loaded() -> bool:
	if _loaded:
		return _grid > 0
	_loaded = true
	if not FileAccess.file_exists(HEIGHTS_PATH):
		push_warning("TerrainHeight: 缺少高度场，所有单位会贴 y=0")
		_grid = 0
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(HEIGHTS_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		_grid = 0
		return false
	var d: Dictionary = parsed
	_grid = int(d.get("grid", 0))
	_cell = float(d.get("cell_m", 1.6))
	_half = float(d.get("map_size_m", 320.0)) * 0.5
	_min_h = float(d.get("height_min", 0.0))
	var arr: Array = d.get("heights", [])
	_data = PackedFloat32Array()
	_data.resize(arr.size())
	for i in range(arr.size()):
		_data[i] = float(arr[i])
	return _grid > 1


## 双线性采样。索引约定与生成器一致：x = -half + i*cell，z = +half - j*cell。
static func at(x: float, z: float) -> float:
	if not ensure_loaded():
		return 0.0
	var fx := (x + _half) / _cell
	var fz := (_half - z) / _cell
	var i := int(floor(fx))
	var j := int(floor(fz))
	var u := fx - float(i)
	var v := fz - float(j)
	i = clampi(i, 0, _grid - 1)
	j = clampi(j, 0, _grid - 1)
	var i1 := mini(i + 1, _grid - 1)
	var j1 := mini(j + 1, _grid - 1)
	var g := _grid
	var h00 := _data[j * g + i]
	var h10 := _data[j * g + i1]
	var h01 := _data[j1 * g + i]
	var h11 := _data[j1 * g + i1]
	var a := lerpf(h00, h10, u)
	var b := lerpf(h01, h11, u)
	return lerpf(a, b, v)


## 水面高度：河道内返回河床以上一点点，用来把「不能下水」表达成视觉
static func is_underwater(x: float, z: float) -> bool:
	return at(x, z) < _min_h + 0.6