class_name AudioLayer
extends Node
## 表现层 · 音效（P0-8）：事件 → 短音效，播放器池 + 每音效冷却 + 随机音高。
## 素材是 tools/sfx_gen.py 生成的占位件；换成正式素材只需要替换同名 wav，接线不动。
## 音量走 Master 总线，所以设置面板的「主音量」直接生效。

const DIR := "res://art/assets/audio/"
const PLAYERS := 10

## id -> {file, db, cooldown, pitch}；pitch 是 ±随机比例，避免连发听成机关枪
const SFX := {
	"shot": {"file": "sfx_shot.wav", "db": -11.0, "cooldown": 0.045, "pitch": 0.05},
	"knife": {"file": "sfx_knife.wav", "db": -13.0, "cooldown": 0.05, "pitch": 0.08},
	"hit": {"file": "sfx_hit.wav", "db": -15.0, "cooldown": 0.035, "pitch": 0.10},
	"kill": {"file": "sfx_kill.wav", "db": -8.0, "cooldown": 0.05, "pitch": 0.08},
	"repair": {"file": "sfx_repair.wav", "db": -8.0, "cooldown": 0.08, "pitch": 0.06},
	"buy": {"file": "sfx_buy.wav", "db": -9.0, "cooldown": 0.05, "pitch": 0.02},
	"loot": {"file": "sfx_loot.wav", "db": -9.0, "cooldown": 0.06, "pitch": 0.04},
	"reveal": {"file": "sfx_reveal.wav", "db": -10.0, "cooldown": 0.04, "pitch": 0.05},
	"scan_tick": {"file": "sfx_scan_tick.wav", "db": -20.0, "cooldown": 0.10, "pitch": 0.08},
	"breach": {"file": "sfx_breach.wav", "db": -4.0, "cooldown": 1.0, "pitch": 0.0},
	"crystal": {"file": "sfx_crystal.wav", "db": -6.0, "cooldown": 0.12, "pitch": 0.03},
	"hurt": {"file": "sfx_hurt.wav", "db": -7.0, "cooldown": 0.15, "pitch": 0.05},
	"wave": {"file": "sfx_wave.wav", "db": -6.0, "cooldown": 2.0, "pitch": 0.0},
	"heartbeat": {"file": "sfx_heartbeat.wav", "db": -9.0, "cooldown": 0.55, "pitch": 0.0},
}

var streams := {}
var missing := {}          # id -> path（缺文件时记下来，不反复 load）
var played := {}           # id -> 实际播放次数（给测试与调试用）
var _players: Array = []
var _last := {}
var _next := 0
var _rng := RandomNumberGenerator.new()


func setup() -> void:
	_rng.randomize()
	for i in range(PLAYERS):
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)
	for id in SFX:
		var path: String = DIR + str(SFX[id]["file"])
		if not ResourceLoader.exists(path):
			missing[id] = path
			push_warning("[audio] 缺文件：" + path)
			continue
		streams[id] = load(path)


## 返回是否真的播了：冷却内 / 缺素材都会返回 false，调用方不需要判断
func play(id: String) -> bool:
	if not streams.has(id):
		return false
	var cfg: Dictionary = SFX[id]
	var now := Time.get_ticks_msec() / 1000.0
	if now - float(_last.get(id, -99.0)) < float(cfg["cooldown"]):
		return false
	_last[id] = now
	var p := _free_player()
	p.stream = streams[id]
	p.volume_db = float(cfg["db"])
	var pitch := float(cfg["pitch"])
	p.pitch_scale = _rng.randf_range(1.0 - pitch, 1.0 + pitch) if pitch > 0.0 else 1.0
	p.play()
	played[id] = int(played.get(id, 0)) + 1
	return true


func _free_player() -> AudioStreamPlayer:
	# 先找空闲的；都在播就轮转抢一个（都是短音，抢占听不出来）
	for i in range(_players.size()):
		var idx := (_next + i) % _players.size()
		var p: AudioStreamPlayer = _players[idx]
		if not p.playing:
			_next = (idx + 1) % _players.size()
			return p
	var fallback: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	return fallback


func count(id: String) -> int:
	return int(played.get(id, 0))


func reset_counts() -> void:
	played.clear()
	_last.clear()          # 测试里连帧调用时，冷却也要一起清，否则计数会被挡住