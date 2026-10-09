@tool
extends Area2D
## Weight plate: a floor plate that is a power SOURCE (see power_target.gd for the contract), powered while the
## summed weight resting on it reaches `threshold`. Emits `powered_changed(on)` and answers `is_powered()`;
## PowerTargets pick it in their `sources` list and conductor wires attach to it by adjacency, like a Button.
##
## Weight is in the units the see-saw already uses: a MeltableBlock's engine `mass` (set per 16px tile in its scene:
## metal 4, ice 1) and the player's `player_weight` (2, the same default as RotatingBody). Enemies and liquid weigh
## nothing, so they never press it. The default `threshold` of 2 is the player alone; an ice block (1) is not
## enough alone, two stacked are, and a metal block is. A melting ice block lowers the reading, so a plate can
## release by itself, which makes it a timer.
##
## What counts: the sensor is a strip straddling the top of the pedestal (the same geometry as Button's), polled every
## physics frame like Button, Sawwheel and Crusher rather than through body_entered/exited, so a block that melts
## on the plate can't leave it stuck. Each body overlapping the strip counts once. The player counts only while on the
## floor, so jumping through the strip doesn't. Blocks (and the player) resting on a block that is on the plate
## count too, up to MAX_STACK_DEPTH levels, found with a thin band above each of its shapes, like the see-saw's
## load scan (a player on a block on the plate loads it). A candidate must be centred above the block under it, so a
## block standing beside it doesn't count. A block merely falling through the strip counts for the frames it overlaps.
##
## Power: rises the physics frame the reading reaches `threshold`; falls once it has been below it for `hold_time`
## seconds (default 0.15), which absorbs a block bobbing on the plate or a reading that dips for a frame. Hold is the
## shared rule for a source read from an analogue quantity (no hysteresis is needed on top of it).
##
## Pedestal: a child StaticBody2D (layer 2, "water_solid", not "ground"/"catwalk", so it can't be ledge-grabbed)
## whose top sinks 2px while powered (eased at SINK_SPEED), so the plate visibly gives under load.
##
## Expected scene layout (weight_plate.tscn):
##   WeightPlate (Area2D, this script, collision_layer 0, collision_mask 1)
##     - CollisionShape2D   (sensor strip)
##     - Solid (StaticBody2D, layer 2)
##         - CollisionShape2D   (RectangleShape2D; resized by this script at runtime)
##
## Origin: the centre of a 16x16 tile (the cell a ConductorLayer files it under, like Button). Art is drawn in code
## (a slab with a fill bar showing weight against the threshold) until sprites exist; `show_weight` prints the
## live reading above it at runtime, for tuning a threshold. Sounds `interactive/weight_plate_press` and
## `interactive/weight_plate_release` (on a change of `powered`) are in Audio.PLANNED.
##
## Saveable: `powered` and `time_left`. The state is derived from what is on the plate, but it is still saved: a
## fresh plate starts unpowered and would rise on the first physics frame after a restore (a rising edge turns a
## wired mirror a step). `load_state()` snaps silently and emits `powered_changed` only on a change. A restored plate
## keeps its power for RESTORE_GRACE_FRAMES physics frames even if the sensor reads empty, because a restored block
## only overlaps the strip once the physics server has stepped (Button does the same).

signal powered_changed(on: bool)

## Summed weight (block-mass units) at which the plate powers. 2 = the player alone by default.
@export_range(0.5, 40.0, 0.5, "or_greater") var threshold: float = 2.0
## Seconds the reading must stay below `threshold` before the plate releases. 0 = releases the same frame.
@export_range(0.0, 5.0, 0.05, "or_greater") var hold_time: float = 0.15
## The player's weight, in the same units as a block's `mass` (matches RotatingBody.player_weight).
@export var player_weight: float = 2.0
## Runtime only: draw the live weight and threshold above the plate, for tuning.
@export var show_weight: bool = false
@export var draw_placeholder: bool = true

const HALF_TILE := 8.0
const SURFACE_TOP := -5.0 ## local y of the pedestal's top when not pressed (Button's resting height).
const SINK_PX := 2.0 ## how far the top sinks while powered.
const SINK_SPEED := 30.0 ## px/s the top moves at.
const SOLID_WIDTH := 14.0
const RIDER_MASK := 1 ## layer 1: the player, enemies and blocks (blocks are layers 1|2).
const RIDER_BAND := 3.0 ## px above a block's shape that counts as "on it" for the stack query.
const MAX_STACK_DEPTH := 3 ## levels of blocks (and what stands on them) counted above the plate.
const RESTORE_GRACE_FRAMES := 3
const COLOR_SLAB := Color(0.34, 0.36, 0.42)
const COLOR_SLAB_ON := Color(0.35, 0.8, 0.45)
const COLOR_EDGE := Color(0.6, 0.63, 0.7)
const COLOR_BAR := Color(1.0, 0.75, 0.25)

var powered: bool = false
var weight: float = 0.0 ## The reading from the last physics frame.
var _time_left: float = 0.0 ## Hold remaining while the reading is below the threshold.
var _sink: float = 0.0
var _restore_grace: int = 0
var _drawn_weight: float = -1.0

@onready var _solid: StaticBody2D = $Solid
@onready var _solid_shape: CollisionShape2D = $Solid/CollisionShape2D

func _ready() -> void:
	add_to_group(&"power_source")  # what ConductorLayer scans to attach sources to circuits by adjacency
	queue_redraw()
	if Engine.is_editor_hint():
		set_physics_process(false)  # the scene file already holds the resting collider
		return
	add_to_group(&"saveable")
	# The shape resource is shared by every instance of this scene: give this one its own before it is resized.
	_solid_shape.shape = RectangleShape2D.new()
	_sync_solid()
	_solid.add_to_group(&"water_solid")  # collision only; water rests on the pedestal

## Power-source contract (PowerTarget and conductor circuits read this).
func is_powered() -> bool:
	return powered

## Saveable contract (see game.gd).
func save_state() -> Dictionary:
	return {"powered": powered, "time_left": _time_left}

## Snaps with no sound: the pedestal goes straight to its sunk or resting height. Emits powered_changed only if
## `powered` differs from the current value; the live reading takes over from the next physics frame.
func load_state(d: Dictionary) -> void:
	var was := powered
	powered = d.get("powered", false)
	_time_left = float(d.get("time_left", 0.0)) if powered else 0.0
	if powered and _time_left <= 0.0:
		_time_left = hold_time
	_restore_grace = RESTORE_GRACE_FRAMES if powered else 0
	_sink = SINK_PX if powered else 0.0
	_sync_solid()
	queue_redraw()
	if powered != was:
		powered_changed.emit(powered)

func _physics_process(delta: float) -> void:
	weight = _read_weight()
	if weight >= threshold:
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
	var target := SINK_PX if powered else 0.0
	if not is_equal_approx(_sink, target):
		_sink = move_toward(_sink, target, SINK_SPEED * delta)
		_sync_solid()
		queue_redraw()
	if not is_equal_approx(weight, _drawn_weight):
		_drawn_weight = weight
		queue_redraw()

func _set_powered(on: bool) -> void:
	if on == powered:
		return
	powered = on
	if not on:
		_time_left = 0.0
	Audio.play_at(&"interactive/weight_plate_press" if on else &"interactive/weight_plate_release", global_position)
	queue_redraw()
	powered_changed.emit(on)

# --- weight reading -------------------------------------------------------------------------------

## Sum of the weights resting on the plate this frame: everything overlapping the strip, plus what rests on blocks
## that are on it. Each body counts once.
func _read_weight() -> float:
	var total := 0.0
	var seen := {}
	for body in get_overlapping_bodies():
		total += _weight_with_stack(body, seen, 0)
	return total

## `body`'s own weight plus whatever stands on it (if it is a block), or 0 if it has no weight, was already counted
## or (the player) isn't on the floor.
func _weight_with_stack(body: Object, seen: Dictionary, depth: int) -> float:
	var physics_body := body as PhysicsBody2D
	if physics_body == null or seen.has(physics_body.get_instance_id()):
		return 0.0
	var own := _weight_of(physics_body)
	if own <= 0.0:
		return 0.0
	seen[physics_body.get_instance_id()] = true
	if depth < MAX_STACK_DEPTH and physics_body is RigidBody2D:
		own += _stack_above(physics_body, seen, depth + 1)
	return own

## Weight in block-mass units: a MeltableBlock's `mass`, the player's `player_weight` while on the floor, nothing
## else (enemies are weightless).
func _weight_of(body: PhysicsBody2D) -> float:
	if body is MeltableBlock:
		return (body as MeltableBlock).mass
	if body.is_in_group(&"player"):
		var character := body as CharacterBody2D
		return player_weight if character != null and character.is_on_floor() else 0.0
	return 0.0

## What stands on `block`: a band above each of its shapes, straight up in world space. A candidate must be centred
## above the block, which filters out a block touching it sideways.
func _stack_above(block: PhysicsBody2D, seen: Dictionary, depth: int) -> float:
	var total := 0.0
	var params := PhysicsShapeQueryParameters2D.new()
	params.collision_mask = RIDER_MASK
	params.exclude = [block.get_rid()]
	var space := get_world_2d().direct_space_state
	for child in block.get_children():
		var cs := child as CollisionShape2D
		if cs == null or cs.disabled or cs.shape == null:
			continue
		params.shape = cs.shape
		params.transform = cs.global_transform.translated(Vector2(0.0, -RIDER_BAND))
		for hit in space.intersect_shape(params, 16):
			var above := hit["collider"] as Node2D
			if above != null and above.global_position.y < block.global_position.y:
				total += _weight_with_stack(above, seen, depth)
	return total

# --- solid ---------------------------------------------------------------------------------------

## Resize the pedestal so its top follows the sink and its bottom stays on the tile's lower edge.
func _sync_solid() -> void:
	var top := SURFACE_TOP + _sink
	var rect := _solid_shape.shape as RectangleShape2D
	rect.size = Vector2(SOLID_WIDTH, HALF_TILE - top)
	_solid_shape.position = Vector2(0.0, (top + HALF_TILE) * 0.5)

# --- drawing -------------------------------------------------------------------------------------

func _draw() -> void:
	if not draw_placeholder:
		return
	var top := SURFACE_TOP + _sink
	var slab := COLOR_SLAB_ON if powered else COLOR_SLAB
	draw_rect(Rect2(-SOLID_WIDTH * 0.5, top, SOLID_WIDTH, HALF_TILE - top), COLOR_SLAB.darkened(0.3))
	draw_rect(Rect2(-SOLID_WIDTH * 0.5, top, SOLID_WIDTH, 2.0), slab)
	draw_rect(Rect2(-SOLID_WIDTH * 0.5, top, SOLID_WIDTH, HALF_TILE - top), COLOR_EDGE, false, 1.0)
	# A fill bar below the top: how much of the threshold is on the plate.
	var fill := clampf(weight / maxf(threshold, 0.001), 0.0, 1.0) if not Engine.is_editor_hint() else 0.0
	var bar_width := (SOLID_WIDTH - 4.0)
	draw_rect(Rect2(-bar_width * 0.5, top + 4.0, bar_width, 2.0), Color(0.12, 0.13, 0.16))
	if fill > 0.0:
		draw_rect(Rect2(-bar_width * 0.5, top + 4.0, bar_width * fill, 2.0), COLOR_BAR)
	if show_weight and not Engine.is_editor_hint():
		draw_string(ThemeDB.fallback_font, Vector2(-14.0, top - 4.0), "%.1f/%.1f" % [weight, threshold], HORIZONTAL_ALIGNMENT_CENTER, 28.0, 8, Color.WHITE)
