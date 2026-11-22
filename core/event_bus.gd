class_name EventBus
extends RefCounted
## 出站事件总线：core 层只写事件，不直接碰场景/UI。
## 表现层每帧 drain 一次，事件即“这一帧发生了什么”，不承担状态查询职责。

const SHOT_FIRED := "shot_fired"
const ENEMY_HIT := "enemy_hit"
const ENEMY_ATTACK := "enemy_attack"
const ENEMY_DIED := "enemy_died"
const PLAYER_HURT := "player_hurt"
const PLAYER_ROLL := "player_roll"
const PLAYER_BLINK := "player_blink"
const PLAYER_DIED := "player_died"
const PLAYER_RESPAWNED := "player_respawned"
const WALL_HIT := "wall_hit"
const WALL_BREACHED := "wall_breached"
const WALL_REPAIRED := "wall_repaired"
const GUARD_DIED := "guard_died"
const GUARD_REFILLED := "guard_refilled"
const BUILDING_BUILT := "building_built"
const BUILDING_HIT := "building_hit"
const BUILDING_DESTROYED := "building_destroyed"
const BUILDING_DEMOLISHED := "building_demolished"
const BUILDING_REPAIRED := "building_repaired"
const BUILDING_SHOT := "building_shot"
const DROP_PICKED := "drop_picked"
const ITEM_GAINED := "item_gained"
const ITEM_EQUIPPED := "item_equipped"
const CRYSTAL_HIT := "crystal_hit"
const LOOT_OPENED := "loot_opened"
const LOOT_REVEALED := "loot_revealed"
const PHASE_CHANGED := "phase_changed"
const WAVE_STARTED := "wave_started"
const WAVE_CLEARED := "wave_cleared"
const RUN_ENDED := "run_ended"
const PURCHASE := "purchase"
const NOTICE := "notice"

var _queue: Array = []


func emit(type: String, data: Dictionary = {}) -> void:
	_queue.append({"type": type, "data": data})


func drain() -> Array:
	var out := _queue
	_queue = []
	return out


func clear() -> void:
	_queue.clear()
