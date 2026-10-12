@tool
extends Area2D
## Zone sensor: a power SOURCE (see power_target.gd for the contract) that is powered while enough bodies are inside
## a rectangular area. Emits `powered_changed(on)` and answers `is_powered()`; PowerTargets pick it in their `sources`
## list and conductor wires attach to it by adjacency, like a Button. It gives a door that shuts behind the player,
## an ambush trigger, and a lure puzzle where an enemy has to stand in the zone.
##
## Not a physical object: it blocks nothing and is invisible and silent in play by default (see `show_zone` and
## `silent`). `size` is the zone's width and height in pixels, centred on the node origin; the shape is per instance.
## Origin: the cell a ConductorLayer files it under is the cell the origin is in, so for a large zone either wire it
## by `sources` or place it so that cell is where a wire ends.
##
## What counts (`count_player`, `count_enemies`, `count_blocks`, each opt-in; the defaults are the player only): the
## player, any body in group "enemy", any MeltableBlock. Each body overlapping the area counts once, whatever its
## state (a player on a ladder, hanging or swimming counts), except that a dead or dancing player never counts and a
## body already queued for deletion does not. The count is summed across the enabled kinds and the sensor powers
## at `min_count` (default 1) or more; "nobody in the zone" is `invert` on the PowerTarget.
##
## Power: the area is polled every physics frame (get_overlapping_bodies(), never body_entered/exited, so a body
## that melts, dies or is freed inside can't leave it stuck). Rises the physics frame the count reaches `min_count`;
## falls once it has stayed below it for `hold_time` seconds (default 0.15), the shared rule for an analogue source,
## so a body crossing the edge can't chatter it. A body that appears this frame (a spawn, a restore) is seen from the
## next physics step, as with any Area2D.
##
## Saveable: `powered` and `time_left`. The state is derived from what is in the zone, but it is still saved: a fresh
## sensor starts unpowered and would rise on the first physics frame after a restore, and a rising edge turns a wired
## mirror a step. `load_state()` snaps silently and emits `powered_changed` only on a change. A restored sensor keeps
## its power for RESTORE_GRACE_FRAMES physics frames even if it reads empty, because a restored body only overlaps
## the area once the physics server has stepped (Button and the weight plate do the same).
##
## Authoring: the zone outline is always drawn in the editor, and at run time only while `show_zone` is set (with the
## live count over `min_count`). `authoring_overlay` is a plain variable the editor sets in `_ready()` rather than an
## `Engine.is_editor_hint()` test, so a runtime level editor can set it too. `get_warnings()` is a plain method that
## `_get_configuration_warnings()` calls.
## Sounds `interactive/zone_sensor_on` and `interactive/zone_sensor_off` (on a change of `powered`, never within
## QUIET_FRAMES of load, and only when `silent` is off) are in Audio.PLANNED.

signal powered_changed(on: bool)

## Width and height of the zone in pixels, centred on the node origin.
@export var size: Vector2 = Vector2(48.0, 48.0):
	set(value):
		size = Vector2(maxf(value.x, 1.0), maxf(value.y, 1.0))
		_sync_shape()
		update_configuration_warnings()
		queue_redraw()
## Count the player (never while dead or dancing).
@export var count_player: bool = true:
	set(value):
		count_player = value
		update_configuration_warnings()
## Count bodies in group "enemy".
@export var count_enemies: bool = false:
	set(value):
		count_enemies = value
		update_configuration_warnings()
## Count MeltableBlocks (ice and metal).
@export var count_blocks: bool = false:
	set(value):
		count_blocks = value
		update_configuration_warnings()
## Bodies (summed across the enabled kinds) needed to power the sensor.
@export_range(1, 32, 1, "or_greater") var min_count: int = 1:
	set(value):
		min_count = maxi(value, 1)
		queue_redraw()
## Seconds the count must stay below `min_count` before the sensor releases. 0 = releases the same frame.
@export_range(0.0, 5.0, 0.05, "or_greater") var hold_time: float = 0.15
## Draw the zone at run time (it is always drawn in the editor).
@export var show_zone: bool = false:
	set(value):
		show_zone = value
		queue_redraw()
## No on/off sounds (the default: an ambush trigger shouldn't click). Turn off to play them.
@export var silent: bool = true

const QUIET_FRAMES := 3 ## No sound for a change this soon after load.
const RESTORE_GRACE_FRAMES := 3
const COLOR_FILL := Color(0.3, 0.75, 0.9, 0.10)
const COLOR_FILL_ON := Color(0.35, 0.9, 0.45, 0.18)
const COLOR_EDGE := Color(0.3, 0.75, 0.9, 0.8)
const COLOR_EDGE_ON := Color(0.35, 0.9, 0.45, 0.9)

var powered: bool = false
var count: int = 0 ## The reading from the last physics frame.
var authoring_overlay: bool = false ## Draw the zone regardless of `show_zone` (the editor sets it in `_ready()`).
var _time_left: float = 0.0 ## Hold remaining while the count is below `min_count` and the sensor is powered.
var _restore_grace: int = 0
var _ready_frame: int = 0
var _drawn_count: int = -1

@onready var _shape_node: CollisionShape2D = $CollisionShape2D

func _ready() -> void:
	add_to_group(&"power_source")  # what ConductorLayer scans to attach sources to circuits by adjacency
	authoring_overlay = Engine.is_editor_hint()
	# The shape resource is shared by every instance of this scene: give this one its own before it is resized.
	_shape_node.shape = RectangleShape2D.new()
	_sync_shape()
	queue_redraw()
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	add_to_group(&"saveable")
	_ready_frame = Engine.get_physics_frames()

## Resizes this instance's shape from `size`. Named so an editor can re-run it after a change.
func _sync_shape() -> void:
	if _shape_node == null or not (_shape_node.shape is RectangleShape2D):
		return
	(_shape_node.shape as RectangleShape2D).size = size

func _get_configuration_warnings() -> PackedStringArray:
	return get_warnings()

## Plain method so a runtime level validator can reuse the warnings.
func get_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not (count_player or count_enemies or count_blocks):
		warnings.append("None of `count_player`, `count_enemies` and `count_blocks` is on, so this sensor can never power.")
	if rotation != 0.0 or scale != Vector2.ONE:
		warnings.append("The zone is `size` px and axis-aligned; rotation and scale distort it, so leave them at their defaults and change `size` instead.")
	return warnings

## Power-source contract (PowerTarget and conductor circuits read this).
func is_powered() -> bool:
	return powered

## Saveable contract (see game.gd).
func save_state() -> Dictionary:
	return {"powered": powered, "time_left": _time_left}

## Snaps with no sound. Emits powered_changed only if `powered` differs from the current value; the live reading
## takes over from the next physics frame, after the restore grace.
func load_state(d: Dictionary) -> void:
	var was := powered
	powered = d.get("powered", false)
	_time_left = float(d.get("time_left", 0.0)) if powered else 0.0
	if powered and _time_left <= 0.0:
		_time_left = hold_time
	_restore_grace = RESTORE_GRACE_FRAMES if powered else 0
	queue_redraw()
	if powered != was:
		powered_changed.emit(powered)

func _physics_process(delta: float) -> void:
	count = _read_count()
	if count >= min_count:
		_time_left = hold_time
		_restore_grace = 0
		_set_powered(true)
	elif powered:
		if _restore_grace > 0:
			_restore_grace -= 1
		else:
			_time_left = maxf(_time_left - delta, 0.0)
			if _time_left <= 0.0:
				_set_powered(false)
	if count != _drawn_count:
		_drawn_count = count
		if show_zone or authoring_overlay:
			queue_redraw()

func _set_powered(on: bool) -> void:
	if on == powered:
		return
	powered = on
	if not on:
		_time_left = 0.0
	if not silent and Engine.get_physics_frames() - _ready_frame > QUIET_FRAMES:
		Audio.play_at(&"interactive/zone_sensor_on" if on else &"interactive/zone_sensor_off", global_position)
	queue_redraw()
	powered_changed.emit(on)

# --- reading ----------------------------------------------------------------------------------------

## How many counted bodies overlap the zone this frame. Each body counts once.
func _read_count() -> int:
	var total := 0
	for body in get_overlapping_bodies():
		if _counts(body):
			total += 1
	return total

## Whether `body` counts under the enabled kinds. A dead or dancing player never counts.
func _counts(body: Node) -> bool:
	if body == null or body.is_queued_for_deletion():
		return false
	if count_player and body.is_in_group(&"player"):
		return body.get("is_dead") != true and body.get("is_dancing") != true
	if count_enemies and body.is_in_group(&"enemy"):
		return true
	return count_blocks and body is MeltableBlock

# --- drawing ----------------------------------------------------------------------------------------

func _draw() -> void:
	if not (show_zone or authoring_overlay):
		return
	var rect := Rect2(-size * 0.5, size)
	draw_rect(rect, COLOR_FILL_ON if powered else COLOR_FILL)
	draw_rect(rect, COLOR_EDGE_ON if powered else COLOR_EDGE, false, 1.0)
	if not Engine.is_editor_hint():
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(2.0, 9.0), "%d/%d" % [count, min_count], HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color.WHITE)
