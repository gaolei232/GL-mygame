class_name HudSkin
extends RefCounted
## HUD 皮肤层 —— 集中加载 art/assets 下的运行时纹理，并封装 HUD 用到的绘制原语。
##
## 设计约束：
## 1. 纹理路径只在这一个字典里出现，改图不改调用方。
## 2. 任何一张图缺失都只降级为程序化绘制，绝不让 HUD 因缺图报错。
## 3. 只做"画"这一件事，不持有游戏状态，可被任意 Control 复用。

## 纹理键 -> res:// 路径。键名与用途对齐，不用文件名。
const TEX: Dictionary = {
	"bar_bg": "res://art/assets/ui/ui_bar_bg_v1.png",
	"bar_fill": "res://art/assets/ui/ui_bar_fill_v1.png",
	"bar_frame": "res://art/assets/ui/ui_bar_frame_v1.png",
	"gauge_7seg": "res://art/assets/ui/ui_wall_gauge_7seg360_v1.png",
	"icon_coin": "res://art/assets/icon/icon_coin_small_v1.png",
	"icon_brick": "res://art/assets/icon/icon_brick_small_v1.png",
	"icon_metal": "res://art/assets/icon/icon_metal_small_v1.png",
	"icon_ammo": "res://art/assets/icon/icon_ammo_small_v1.png",
	"icon_crossbow": "res://art/assets/icon/icon_weapon_crossbow_v1.png",
	"icon_hammer": "res://art/assets/icon/icon_tool_hammer_v1.png",
	"icon_knife": "res://art/assets/icon/icon_tool_knife_v1.png",
	"slot_frame": "res://art/assets/ui/ui_slot_frame_v1.png",
	"crosshair": "res://art/assets/ui/ui_crosshair_normal_v1.png",
	"cell_intact": "res://art/assets/ui/ui_wall_cell_intact24_v1.png",
	"cell_damaged": "res://art/assets/ui/ui_wall_cell_damaged24_v1.png",
	"cell_breached": "res://art/assets/ui/ui_wall_cell_breached24_v1.png",
	"danger_edge": "res://art/assets/ui/ui_danger_edge_v1.png",
	"danger_chevron": "res://art/assets/ui/ui_danger_chevron_v1.png",
	"panel": "res://art/assets/ui/ui_panel_bastion_normal_v1.png",
	"btn_normal": "res://art/assets/ui/ui_btn_primary_normal_v1.png",
	"btn_pressed": "res://art/assets/ui/ui_btn_primary_pressed_v1.png",
	"btn_disabled": "res://art/assets/ui/ui_btn_primary_disabled_v1.png",
	"notice_ribbon": "res://art/assets/ui/ui_notice_ribbon_v1.png",
	"reward_card": "res://art/assets/ui/ui_reward_card_frame_v1.png",
}

## 血条三件套横向可拉伸边距（像素）。竖边距为 0：这三张图是 16px 高的扁平条，
## 纵向按目标高度整体拉伸即可，加边距反而会在缩放时压出断线。
const BAR_MARGIN_X: float = 8.0
## 槽位框九宫格边距（120² 图，圆角约 20；目标矩形 52px 时收到 16，否则边距吃掉中心区）。
const SLOT_MARGIN: float = 16.0

var _cache: Dictionary = {}   # String -> Texture2D（含 null，表示已查找过且缺失）


## 取纹理；缺失返回 null（调用方据此降级）。
func tex(key: String) -> Texture2D:
	if _cache.has(key):
		return _cache[key] as Texture2D
	var path: String = str(TEX.get(key, ""))
	var t: Texture2D = load(path) as Texture2D if path != "" else null
	if t == null and path != "":
		push_warning("HudSkin: 纹理缺失 %s（降级为程序化绘制）" % path)
	_cache[key] = t
	return t


## 九宫格绘制（自实现，不依赖 StyleBoxTexture）。
## Godot 4 的 CanvasItem 没有 draw_nine_patch —— 九宫格归 StyleBox 管；
## 但这里要的是"带 modulate 的直接绘制"，自己切 9 块反而更短、更可控。
## margin_x / margin_y 为 0 时对应方向不切片（整条拉伸）。
func draw_np(ci: CanvasItem, t: Texture2D, rect: Rect2, margin_x: float, margin_y: float,
		tint: Color = Color(1, 1, 1, 1)) -> void:
	var tw := float(t.get_width())
	var th := float(t.get_height())
	var mx := clampf(margin_x, 0.0, minf(rect.size.x * 0.5, tw * 0.5))
	var my := clampf(margin_y, 0.0, minf(rect.size.y * 0.5, th * 0.5))
	var cw := rect.size.x - mx * 2.0
	var ch := rect.size.y - my * 2.0
	var xs := [0.0, mx, rect.size.x - mx]
	var ws := [mx, cw, mx]
	var src_xs := [0.0, mx, tw - mx]
	var src_ws := [mx, tw - mx * 2.0, mx]
	var ys := [0.0, my, rect.size.y - my]
	var hs := [my, ch, my]
	var src_ys := [0.0, my, th - my]
	var src_hs := [my, th - my * 2.0, my]
	for row in range(3):
		for col in range(3):
			var w: float = ws[col]
			var h: float = hs[row]
			if w <= 0.0 or h <= 0.0:
				continue
			ci.draw_texture_rect_region(t,
				Rect2(rect.position + Vector2(xs[col], ys[row]), Vector2(w, h)),
				Rect2(src_xs[col], src_ys[row], src_ws[col], src_hs[row]), tint)


## 血条：底 → 填充（按 tint 染色）→ 外框。ratio < 0.001 时只画底与外框。
## fill 是纯白图，颜色一律通过 modulate 给，不另存彩色版本。
func draw_bar(ci: CanvasItem, rect: Rect2, ratio: float, tint: Color) -> void:
	var bg := tex("bar_bg")
	var fill := tex("bar_fill")
	var frame := tex("bar_frame")
	if bg == null or fill == null:
		ci.draw_rect(rect, Color(1, 1, 1, 0.10))
		ci.draw_rect(Rect2(rect.position, Vector2(rect.size.x * clampf(ratio, 0.0, 1.0), rect.size.y)), tint)
		return
	var m := BAR_MARGIN_X
	draw_np(ci, bg, rect, m, 0.0)
	var r := clampf(ratio, 0.0, 1.0)
	if r > 0.001:
		# 填充条最窄保留 2×边距宽度，否则九宫格会被压成负宽度、出现断裂（清单 §6.1）
		var w := maxf(rect.size.x * r, m * 2.0)
		draw_np(ci, fill, Rect2(rect.position, Vector2(w, rect.size.y)), m, 0.0, tint)
	if frame != null:
		draw_np(ci, frame, rect, m, 0.0)


## 城墙 7 格刻度：整体按总血量比例裁切显示，未填充部分保留 18% 透明度的底。
func draw_gauge(ci: CanvasItem, rect: Rect2, ratio: float) -> void:
	var t := tex("gauge_7seg")
	if t == null:
		ci.draw_rect(rect, Color(1, 1, 1, 0.12))
		ci.draw_rect(Rect2(rect.position, Vector2(rect.size.x * clampf(ratio, 0.0, 1.0), rect.size.y)),
			Color(0.85, 0.78, 0.60))
		return
	ci.draw_texture_rect(t, rect, false, Color(1, 1, 1, 0.18))
	var r := clampf(ratio, 0.0, 1.0)
	if r > 0.001:
		var src_w := t.get_width() * r
		ci.draw_texture_rect_region(t, Rect2(rect.position, Vector2(rect.size.x * r, rect.size.y)),
			Rect2(0.0, 0.0, src_w, float(t.get_height())))


## 图标：按目标矩形等比绘制（96² 源图，HUD 上 18–34px）。
func draw_icon(ci: CanvasItem, key: String, rect: Rect2) -> void:
	var t := tex(key)
	if t == null:
		return
	ci.draw_texture_rect(t, rect, false)


## 槽位框 + 选中描边。active 时用暖金色描边（沿用既有配色）。
func draw_slot(ci: CanvasItem, rect: Rect2, active: bool) -> void:
	var t := tex("slot_frame")
	if t == null:
		ci.draw_rect(rect, Color(0.16, 0.17, 0.20, 0.85))
	else:
		draw_np(ci, t, rect, SLOT_MARGIN, SLOT_MARGIN)
	if active:
		ci.draw_rect(rect, Color(0.95, 0.80, 0.42, 0.85), false, 2.0)


## 准星：精确瞄准时叠一层放大 + 暖色偏移的副本。
func draw_crosshair(ci: CanvasItem, center: Vector2, focus: bool) -> void:
	var t := tex("crosshair")
	if t == null:
		ci.draw_arc(center, 9.0, 0.0, TAU, 24, Color(1, 1, 1, 0.75), 1.5)
		return
	if focus:
		var big := Rect2(center - Vector2(22, 22), Vector2(44, 44))
		ci.draw_texture_rect(t, big, false, Color(1.0, 0.85, 0.45, 0.55))
	var box := Rect2(center - Vector2(16, 16), Vector2(32, 32))
	ci.draw_texture_rect(t, box, false)


## 墙段状态标记：0=完好 1=受损 2=破口，用墙格三态贴图。
## 按源图原尺寸 24×18 画（不放大会变成贴在墙上的"便利贴"，比敌人还抢眼），
## alpha 压到 0.9 让它退到次体层。
func draw_wall_cell(ci: CanvasItem, center: Vector2, state: int) -> void:
	var keys := ["cell_intact", "cell_damaged", "cell_breached"]
	var t := tex(str(keys[clampi(state, 0, 2)]))
	if t == null:
		return
	ci.draw_texture_rect(t, Rect2(center - Vector2(12, 9), Vector2(24, 18)), false, Color(1, 1, 1, 0.9))


## 破口警示：四边脉动条（整屏拉伸）+ 破口段上的三角标。
## 注意：danger_edge 资产自身的边缘 alpha 峰值已是 89/255（≈0.35），
## modulate 若是 0.2 级会把有效 alpha 压到 0.07、肉眼不可见。
## 这里把 modulate 控制在 0.55–1.0，有效峰值才落在清单要求的 0.35 附近。
func draw_danger(ci: CanvasItem, vp: Vector2, chevrons: Array[Vector2], pulse: float) -> void:
	var edge := tex("danger_edge")
	var k := 0.55 + 0.45 * pulse
	if edge != null:
		ci.draw_texture_rect(edge, Rect2(Vector2.ZERO, vp), false, Color(1, 1, 1, k))
	var chev := tex("danger_chevron")
	if chev == null:
		return
	for p in chevrons:
		ci.draw_texture_rect(chev, Rect2(p - Vector2(12, 12), Vector2(24, 24)), false,
			Color(1, 1, 1, 0.6 + 0.4 * pulse))


## 顶部提示条底（toast）。ribbon 源图 512×48，横向边距 12，纵向整体压缩。
func draw_notice(ci: CanvasItem, rect: Rect2, alpha: float) -> void:
	var t := tex("notice_ribbon")
	if t == null:
		ci.draw_rect(rect, Color(0.06, 0.07, 0.09, 0.72 * alpha))
		return
	draw_np(ci, t, rect, 12.0, 0.0, Color(1, 1, 1, clampf(alpha, 0.0, 1.0)))


## 生成 StyleBoxTexture；缺图返回 null，调用方据此跳过。
## margin 是贴图边距（保护圆角），content 是内边距（文字不贴边），tint 为整张贴图的乘法颜色。
func _sb(key: String, margin: float, content: float,
		tint: Color = Color(1, 1, 1, 1)) -> StyleBoxTexture:
	var t := tex(key)
	if t == null:
		return null
	var sb := StyleBoxTexture.new()
	sb.texture = t
	sb.texture_margin_left = margin
	sb.texture_margin_top = margin
	sb.texture_margin_right = margin
	sb.texture_margin_bottom = margin
	sb.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	sb.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	sb.content_margin_left = content
	sb.content_margin_top = content * 0.5
	sb.content_margin_right = content
	sb.content_margin_bottom = content * 0.5
	sb.modulate_color = tint
	return sb


## 面板底 StyleBox。缺图返回 null，Panel 会退回默认样式（不会崩）。
func panel_style() -> StyleBox:
	return _sb("panel", 32.0, 14.0)


## 奖励卡外框 StyleBox：源图 220×300，四角有铆钉，边距 20 不许拉伸；内容边距 24。
## 这张是竖卡，只在"三列卡片"布局里按原尺寸用，不能当横向面板底（见接线记录 §4.4）。
##
## 必须染色：卡框原色是中性灰 200，直接用会在暗场景里变成三块发白的相框。
## 资产清单的用法就是"灰度底供代码染色"——按参考灰 200 归一，倍率 = 目标色 / 200。
## 这里染到 ≈124 的暖钢灰（0.62×200），与全局金色描边同族。
func card_style() -> StyleBox:
	return _sb("reward_card", 20.0, 24.0, Color(0.62, 0.60, 0.56))


## 构建 UI Theme：按钮三态 + 面板底。挂在 Hud 上，整棵子树继承。
## 按钮源图 240×88、原始边距 24；本项目按钮高 44，边距收到 18，
## 否则上下边距(24+24)比按钮本身还高，引擎会强行压缩导致圆角变形。
func build_theme() -> Theme:
	var th := Theme.new()
	var normal := _sb("btn_normal", 18.0, 10.0)
	if normal != null:
		th.set_stylebox("normal", "Button", normal)
		# 没有 hover 贴图：hover 复用 normal，靠字体提亮表达反馈
		th.set_stylebox("hover", "Button", normal)
	var pressed := _sb("btn_pressed", 18.0, 10.0)
	if pressed != null:
		th.set_stylebox("pressed", "Button", pressed)
	var disabled := _sb("btn_disabled", 18.0, 10.0)
	if disabled != null:
		th.set_stylebox("disabled", "Button", disabled)
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_font_size("font_size", "Button", 13)
	th.set_color("font_color", "Button", Color(0.90, 0.92, 0.95))
	th.set_color("font_hover_color", "Button", Color(1.0, 0.97, 0.90))
	th.set_color("font_pressed_color", "Button", Color(0.95, 0.80, 0.42))
	th.set_color("font_disabled_color", "Button", Color(0.52, 0.55, 0.60))
	return th
