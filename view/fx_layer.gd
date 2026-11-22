class_name FxLayer
extends Node3D
## 表现层 · 瞬时反馈：射击弹道、破口闪光。
## 只消费事件，不持有任何玩法状态；所有特效都是“短生命周期的视觉噪声”。

const TRACER_LIFE := 0.07
## 命中火花：P0 资产 fx_hit_spark 还没出图，这里先用「加色小球爆开」占位，
## 接口与真图一致（位置 + 颜色 + 半径），换图时只改 _spark_mesh 的材质。
const SPARK_LIFE := 0.16
const SPARK_POOL := 16

var _tracers: Array = []
var _sparks: Array = []          # {node, life, color, size}
var _spark_free: Array = []
var _mesh_instance: MeshInstance3D
var _im: ImmediateMesh
var _material: StandardMaterial3D


func setup() -> void:
	_im = ImmediateMesh.new()
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = Color(1.0, 0.92, 0.65)
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.vertex_color_use_as_albedo = true
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = _im
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)
	_build_spark_pool()


func _build_spark_pool() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 8
	sphere.rings = 4
	for i in range(SPARK_POOL):
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.albedo_color = Color(1.0, 0.92, 0.65, 0.85)
		var mi := MeshInstance3D.new()
		mi.mesh = sphere
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_spark_free.append(mi)


## 命中/击杀火花：从池里取一个（池空就直接丢弃，反馈不能因为池满就卡住）
func burst(pos: Vector2, color: Color = Color(1.0, 0.92, 0.65), size: float = 0.55) -> void:
	if _spark_free.is_empty():
		return
	var mi: MeshInstance3D = _spark_free.pop_back()
	mi.visible = true
	mi.position = Vector3(pos.x, 1.05, pos.y)
	mi.scale = Vector3.ONE * (size * 0.35)
	(mi.material_override as StandardMaterial3D).albedo_color = Color(color.r, color.g, color.b, 0.9)
	_sparks.append({"node": mi, "life": SPARK_LIFE, "color": color, "size": size})


func add_tracer(from: Vector2, to: Vector2, color: Color = Color(1.0, 0.92, 0.65)) -> void:
	_tracers.append({
		"from": Vector3(from.x, 1.1, from.y),
		"to": Vector3(to.x, 1.1, to.y),
		"life": TRACER_LIFE,
		"color": color,
	})


func tick(delta: float) -> void:
	for t in _tracers:
		t["life"] = float(t["life"]) - delta
	_tracers = _tracers.filter(func(t): return float(t["life"]) > 0.0)

	for s in _sparks:
		s["life"] = float(s["life"]) - delta
		var k := clampf(float(s["life"]) / SPARK_LIFE, 0.0, 1.0)
		var node: MeshInstance3D = s["node"]
		node.scale = Vector3.ONE * float(s["size"]) * (1.6 - k * 1.1)
		var mat: StandardMaterial3D = node.material_override
		var c: Color = s["color"]
		mat.albedo_color = Color(c.r, c.g, c.b, 0.9 * k)
		if float(s["life"]) <= 0.0:
			node.visible = false
			_spark_free.append(node)
	var alive: Array = []
	for s in _sparks:
		if float(s["life"]) > 0.0:
			alive.append(s)
	_sparks = alive

	_im.clear_surfaces()
	if _tracers.is_empty():
		return
	_im.surface_begin(Mesh.PRIMITIVE_LINES)
	for t in _tracers:
		var alpha: float = clampf(float(t["life"]) / TRACER_LIFE, 0.0, 1.0)
		var c: Color = t["color"]
		c.a = alpha
		_im.surface_set_color(c)
		_im.surface_add_vertex(t["from"])
		_im.surface_set_color(c)
		_im.surface_add_vertex(t["to"])
	_im.surface_end()
