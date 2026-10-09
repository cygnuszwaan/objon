@tool
extends Node2D
## Angle sensor: a power SOURCE (see power_target.gd for the contract) that reads a RotatingBody's tilt. Powered once
## the body has turned `threshold_degrees` or more toward `side`, and released only after it has come back below
## `threshold_degrees - hysteresis_degrees`. Emits `powered_changed(on)` and answers `is_powered()`; PowerTargets
## pick it in their `sources` list and conductor wires attach to it by adjacency, like a Button. It works on any
## RotatingBody: a see-saw tipped to one end powers a door, a swing pumped past an angle gives pumping a goal.
##
## Not a physical object: it has no collision, so it can sit anywhere (on a wall, inside a machine) and is wired
## like any source. Set `body` to the RotatingBody it reads. Origin: the centre of a 16x16 tile (the cell a
## ConductorLayer files it under, like Button). Art is drawn in code (a dial whose needle follows the body's angle,
## a tick at the threshold and a lamp that lights while powered) until sprites exist.
##
## Angle: `RotatingBody.get_angle()`, in degrees here, positive = clockwise on screen (the side the right end
## of a plank goes down). `side` picks which direction counts: CLOCKWISE reads the angle as is, COUNTER_CLOCKWISE
## reads it negated, so the threshold is always a positive number. With `free_rotation` the angle wraps to +/-180
## and the sensor is powered through that sector once per turn, which is rarely what you want; use a limited body.
##
## The editor warnings (unset or wrong `body`, threshold beyond the body's limit) refresh when `body`, `side` or
## `threshold_degrees` change here; if you change the body's own limits, reselect this node or reopen the scene.
##
## Hysteresis is the shared rule for a source read from an analogue quantity: the body creeps and bobs around a
## stop, and a sensor on a body that its own power drives (a motorized body) would otherwise chatter at the
## threshold. The default 3 degrees is wide enough for a see-saw settling against its stop. It is clamped to the
## threshold, so the sensor always releases by the time the body is level.
##
## Derived from the body (which restores its own angle): the sensor reads `get_angle()` directly, with no physics
## overlap to wait for, so a restore needs no grace period. It still saves `powered`: a fresh sensor starts
## unpowered and would rise on the first physics frame after a restore, and a rising edge turns a wired mirror a
## step. `load_state()` snaps silently and emits `powered_changed` only on a change; the live angle takes over from
## the next physics frame, and an angle inside the hysteresis band keeps whichever state was restored.
## Sounds `interactive/angle_sensor_on` and `interactive/angle_sensor_off` (on a change of `powered`) are in
## Audio.PLANNED.

signal powered_changed(on: bool)

enum TiltSide { CLOCKWISE, COUNTER_CLOCKWISE }

## The RotatingBody (see-saw, swing, wheel) to read.
@export var body: NodePath:
	set(value):
		body = value
		update_configuration_warnings()
## Which way of tilt counts. CLOCKWISE = the right end of a plank down.
@export var side: TiltSide = TiltSide.CLOCKWISE:
	set(value):
		side = value
		update_configuration_warnings()
		queue_redraw()
## Degrees of tilt toward `side` at which the sensor powers.
@export_range(0.5, 180.0, 0.5) var threshold_degrees: float = 15.0:
	set(value):
		threshold_degrees = value
		update_configuration_warnings()
		queue_redraw()
## Degrees below the threshold the body must fall back to before the sensor releases.
@export_range(0.0, 45.0, 0.5, "or_greater") var hysteresis_degrees: float = 3.0
@export var draw_placeholder: bool = true

const QUIET_FRAMES := 3 ## No sound for a change this soon after load.
const TILE_HALF := 8.0
const DIAL_RADIUS := 5.5
const NEEDLE_LIMIT := PI * 0.45 ## The needle stops here so it stays inside the tile.
const COLOR_BODY := Color(0.25, 0.27, 0.32)
const COLOR_EDGE := Color(0.55, 0.58, 0.65)
const COLOR_DIAL := Color(0.12, 0.13, 0.16)
const COLOR_NEEDLE := Color(0.9, 0.9, 0.95)
const COLOR_TICK := Color(1.0, 0.75, 0.25)
const COLOR_LAMP_OFF := Color(0.3, 0.1, 0.1)
const COLOR_LAMP_ON := Color(0.35, 0.9, 0.45)

var powered: bool = false
var _body: RotatingBody
var _angle_deg: float = 0.0 ## Signed toward `side`, from the last physics frame.
var _drawn_angle: float = INF
var _ready_frame: int = 0

func _ready() -> void:
	add_to_group(&"power_source")  # what ConductorLayer scans to attach sources to circuits by adjacency
	queue_redraw()
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	add_to_group(&"saveable")
	_ready_frame = Engine.get_physics_frames()
	_body = get_node_or_null(body) as RotatingBody
	if _body == null:
		push_warning("AngleSensor '%s': `body` doesn't point at a RotatingBody; it will stay unpowered." % name)

func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	var target := get_node_or_null(body) as RotatingBody
	if target == null:
		warnings.append("Set `body` to a RotatingBody (see-saw, swing or wheel).")
	elif not target.free_rotation:
		var limit := target.max_angle_degrees if side == TiltSide.CLOCKWISE else -target.min_angle_degrees
		if threshold_degrees > limit:
			warnings.append("threshold_degrees (%.1f) is beyond the body's %.1f degree limit on this side, so it can never power." % [threshold_degrees, limit])
	return warnings

## Power-source contract (PowerTarget and conductor circuits read this).
func is_powered() -> bool:
	return powered

## Saveable contract (see game.gd).
func save_state() -> Dictionary:
	return {"powered": powered}

## Snaps with no sound. Emits powered_changed only if `powered` differs from the current value.
func load_state(d: Dictionary) -> void:
	var was := powered
	powered = d.get("powered", false)
	queue_redraw()
	if powered != was:
		powered_changed.emit(powered)

func _physics_process(_delta: float) -> void:
	if _body == null or not is_instance_valid(_body):
		return
	_angle_deg = rad_to_deg(_body.get_angle()) * (1.0 if side == TiltSide.CLOCKWISE else -1.0)
	if not powered:
		if _angle_deg >= threshold_degrees:
			_set_powered(true)
	elif _angle_deg < _release_degrees():
		_set_powered(false)
	if absf(_angle_deg - _drawn_angle) > 0.25:
		_drawn_angle = _angle_deg
		queue_redraw()

## The angle (toward `side`) below which a powered sensor releases.
func _release_degrees() -> float:
	return threshold_degrees - minf(hysteresis_degrees, threshold_degrees)

func _set_powered(on: bool) -> void:
	if on == powered:
		return
	powered = on
	if Engine.get_physics_frames() - _ready_frame > QUIET_FRAMES:
		Audio.play_at(&"interactive/angle_sensor_on" if on else &"interactive/angle_sensor_off", global_position)
	queue_redraw()
	powered_changed.emit(on)

# --- drawing -------------------------------------------------------------------------------------

func _draw() -> void:
	if not draw_placeholder:
		return
	draw_rect(Rect2(-TILE_HALF, -TILE_HALF, 16, 16), COLOR_BODY)
	draw_rect(Rect2(-TILE_HALF, -TILE_HALF, 16, 16), COLOR_EDGE, false, 1.0)
	var centre := Vector2(0.0, 2.0)
	draw_circle(centre, DIAL_RADIUS, COLOR_DIAL)
	# Tick at the threshold, mirrored for COUNTER_CLOCKWISE so it sits where the needle will reach it.
	var dir_sign := 1.0 if side == TiltSide.CLOCKWISE else -1.0
	var tick := clampf(deg_to_rad(threshold_degrees), 0.0, NEEDLE_LIMIT) * dir_sign
	draw_line(centre + _dir(tick) * (DIAL_RADIUS - 1.5), centre + _dir(tick) * (DIAL_RADIUS + 0.5), COLOR_TICK, 1.0)
	var shown := 0.0 if Engine.is_editor_hint() else clampf(deg_to_rad(_angle_deg) * dir_sign, -NEEDLE_LIMIT, NEEDLE_LIMIT)
	draw_line(centre, centre + _dir(shown) * (DIAL_RADIUS - 1.0), COLOR_NEEDLE, 1.0)
	draw_circle(Vector2(0.0, -5.5), 1.5, COLOR_LAMP_ON if powered else COLOR_LAMP_OFF)

## Unit vector at `angle` radians from straight up, positive toward screen-right (clockwise).
func _dir(angle: float) -> Vector2:
	return Vector2(sin(angle), -cos(angle))
