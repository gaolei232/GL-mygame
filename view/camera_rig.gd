class_name CameraRig
extends Node3D
## 表现层 · 2.5D 相机：正交投影 + 固定偏航 45° / 俯角 52°，跟随玩家，滚轮缩放。
## 边界：相机只决定“看到什么、光标指向哪”，不参与任何命中判定。

var camera: Camera3D
var ortho_size := 22.0
var zoom_min := 16.0
var zoom_max := 30.0
var follow_lerp := 6.0
var focus_factor := 1.0      # 精确瞄准时的正交尺寸系数（0.85）
var focus_lerp := 10.0
var _focus := Vector2.ZERO
var _focus_target := 1.0


func setup(cfg: ConfigDB) -> void:
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	ortho_size = cfg.num("camera", "ortho_size", 22.0)
	zoom_min = cfg.num("camera", "zoom_min", 16.0)
	zoom_max = cfg.num("camera", "zoom_max", 30.0)
	follow_lerp = cfg.num("camera", "follow_lerp", 6.0)
	focus_factor = cfg.num("camera", "focus_factor", 0.85)
	camera.size = ortho_size
	camera.near = 0.1
	camera.far = 200.0
	rotation = Vector3(deg_to_rad(-cfg.num("camera", "pitch_degrees", 52.0)),
		deg_to_rad(cfg.num("camera", "yaw_degrees", 45.0)), 0.0)
	camera.position = Vector3(0, 0, 40)
	add_child(camera)
	camera.current = true


func follow(target: Vector2, delta: float, snap: bool = false) -> void:
	if snap:
		_focus = target
	_focus = _focus.lerp(target, clampf(delta * follow_lerp, 0.0, 1.0))
	position = Vector3(_focus.x, TerrainHeight.at(_focus.x, _focus.y), _focus.y)
	if not is_equal_approx(camera.size, ortho_size * _focus_target):
		var wanted: float = ortho_size * _focus_target
		camera.size = lerpf(camera.size, wanted, clampf(delta * focus_lerp, 0.0, 1.0))


func zoom_by(steps: float) -> void:
	ortho_size = clampf(ortho_size + steps * 1.6, zoom_min, zoom_max)
	camera.size = ortho_size * _focus_target


## 右键精确瞄准：只改可视尺寸，不参与判定
func set_focus_aim(on: bool) -> void:
	_focus_target = focus_factor if on else 1.0


## 屏幕光标 → 地面点（y=0 平面）
func ground_point(screen_pos: Vector2) -> Vector2:
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 1e-5:
		return _focus
	var t := -origin.y / dir.y
	var p := origin + dir * t
	return Vector2(p.x, p.z)
