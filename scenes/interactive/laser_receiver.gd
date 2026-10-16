@tool
extends StaticBody2D
## Laser receiver: a solid block that is a power SOURCE lit by a laser beam (see power_target.gd for the contract).
## Emits `powered_changed(on)` and answers `is_powered()`; PowerTargets pick it in their `sources` list and
## conductor wires attach to it by adjacency, exactly like a Button or the speed trap.
##
## Lit: the laser turret calls `on_laser_hit(point, direction)` on whatever ends a beam, every physics frame it
## is on. The receiver only stamps `Engine.get_physics_frames()`; it counts as lit when the last hit is within
## LIT_FRAMES frames, the same rule MeltableBlock uses, so it doesn't depend on whether the turret or the
## receiver is processed first. It powers while lit and stays powered for `hold_time` seconds after the beam
## leaves (0 = follows the beam exactly). The hold also bridges a beam that flickers, as it does when a moving
## platform or a Stingbot crosses it, and a beam swept across it by a turning mirror.
##
## Opaque like any wall: it is a layer-2 body (mask 0), so the beam stops on it, and anything solid in front of
## it shields it (a metal block lasts about 3 s of lit time before it melts; a moving platform is a shutter).
## It is hit on any face; nothing about it reflects. It joins "water_solid" so liquid rests on it, and not
## "ground"/"catwalk", so it can't be ledge-grabbed. Kicks do nothing to it (layer 1 is not set).
##
## AND gate of two receivers: wire both to one PowerTarget and set `all_required` on it; `invert` makes a NOT.
##
## Origin: the centre of a 16x16 tile (the cell a ConductorLayer files it under, like Button). Art is drawn in
## code (a housing with a lens that glows while powered) until sprites exist.
##
## Saveable: `powered` and `time_left`. The state is derived from the beam, but it is still saved: a fresh
## receiver starts unpowered and would rise on the first physics frame after a restore, and a rising edge turns
## a wired mirror a step. A restore snaps silently and then re-derives from the live beam.
## Sounds `interactive/laser_receiver_on` and `interactive/laser_receiver_off` are in Audio.PLANNED.

signal powered_changed(on: bool)

## Seconds the receiver stays powered after the beam leaves it; 0 = exactly as long as it is lit.
@export_range(0.0, 60.0, 0.05, "or_greater") var hold_time: float = 0.3
@export var draw_placeholder: bool = true

const LIT_FRAMES := 2 ## A hit this many physics frames ago or less counts as lit (same as MeltableBlock).
const QUIET_FRAMES := 3 ## No sound for a change this soon after load: the beam was already on.
const TILE_HALF := 8.0
const COLOR_BODY := Color(0.25, 0.27, 0.32)
const COLOR_EDGE := Color(0.55, 0.58, 0.65)
const COLOR_LENS_OFF := Color(0.3, 0.1, 0.1)
const COLOR_LENS_ON := Color(1.0, 0.35, 0.25)

var powered: bool = false
var _hit_frame: int = -1000
var _time_left: float = 0.0
var _ready_frame: int = 0

@onready var _beam_target: Area2D = get_node_or_null("BeamTarget")

func _ready() -> void:
	add_to_group(&"power_source")  # what ConductorLayer scans to attach sources to circuits by adjacency
	queue_redraw()
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	add_to_group(&"water_solid")  # collision only; static, so carry is inert for it
	add_to_group(&"saveable")
	_ready_frame = Engine.get_physics_frames()

## The Area2D the beam has to reach (see "Beam targets" in laser_beam.gd; the emitter reads this through LaserBeam.hit_counts()).
## Null = the body itself is the target. The shape defaults to the whole 16x16 tile, so shrink it in the editor to make
## the receiver pick a smaller spot.
func get_beam_target() -> Area2D:
	return _beam_target

## Beam contract (LaserTurret._dispatch): called every physics frame the beam ends on this body.
func on_laser_hit(_point: Vector2, _direction: Vector2) -> void:
	_hit_frame = Engine.get_physics_frames()

func is_lit() -> bool:
	return Engine.get_physics_frames() - _hit_frame <= LIT_FRAMES

## Power-source contract (PowerTarget and conductor circuits read this).
func is_powered() -> bool:
	return powered

## Saveable contract (see game.gd).
func save_state() -> Dictionary:
	return {"powered": powered, "time_left": _time_left}

## Snaps with no sound. Emits powered_changed only if `powered` differs from the current value, so circuits and
## targets follow; the live beam takes over from the next physics frame.
func load_state(d: Dictionary) -> void:
	var was := powered
	powered = d.get("powered", false)
	_time_left = float(d.get("time_left", 0.0)) if powered else 0.0
	_hit_frame = -1000
	queue_redraw()
	if powered != was:
		powered_changed.emit(powered)

func _physics_process(delta: float) -> void:
	if is_lit():
		_time_left = hold_time
		_set_powered(true)
	elif powered:
		_time_left = maxf(_time_left - delta, 0.0)
		if _time_left <= 0.0:
			_set_powered(false)

func _set_powered(on: bool) -> void:
	if on == powered:
		return
	powered = on
	if Engine.get_physics_frames() - _ready_frame > QUIET_FRAMES:
		Audio.play_at(&"interactive/laser_receiver_on" if on else &"interactive/laser_receiver_off", global_position)
	queue_redraw()
	powered_changed.emit(on)

# --- drawing -------------------------------------------------------------------------------------

func _draw() -> void:
	if not draw_placeholder:
		return
	draw_rect(Rect2(-TILE_HALF, -TILE_HALF, 16, 16), COLOR_BODY)
	draw_rect(Rect2(-TILE_HALF, -TILE_HALF, 16, 16), COLOR_EDGE, false, 1.0)
	var lens := COLOR_LENS_ON if powered else COLOR_LENS_OFF
	if powered:
		var glow := COLOR_LENS_ON
		glow.a = 0.3
		draw_circle(Vector2.ZERO, 6.0, glow)
	draw_circle(Vector2.ZERO, 3.5, Color(0.1, 0.11, 0.14))
	draw_circle(Vector2.ZERO, 2.5, lens)
