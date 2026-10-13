@tool
extends StaticBody2D
## Freeze receiver: a solid block that is a power SOURCE lit by a freeze beam (see power_target.gd for the contract). The
## freeze ray's counterpart to the laser receiver: it emits `powered_changed(on)` and answers `is_powered()`; PowerTargets
## pick it in their `sources` list and conductor wires attach to it by adjacency, exactly like a Button or the laser receiver.
##
## Lit: the freeze turret calls `on_freeze_hit(point, direction)` on whatever ends a beam, every physics frame it is on.
## The receiver only stamps `Engine.get_physics_frames()`; it counts as lit when the last hit is within LIT_FRAMES frames
## (the laser receiver's rule), so it never depends on whether the turret or the receiver is processed first.
##
## **Dwell**: unlike the laser receiver, the beam has to stay on it. While lit and not yet powered the receiver builds
## frost, one second per second of beam; it powers once the frost reaches `dwell_time` (0 = at once, as a laser receiver
## does). Frost decays at one second per second when the beam is off it, so a beam swept across does nothing and one that
## leaves and comes back keeps what is left. Once powered, a lit receiver holds full frost, stays powered for as long as
## it is lit and for `hold_time` seconds after the beam leaves (0 = follows the beam exactly; the hold also bridges a
## beam that flickers, as when a platform or a Stingbot crosses it). Holding a beam steady on it while mirrors turn is
## the puzzle.
##
## Opaque like any wall: a layer-2 body (mask 0), so the beam stops on it and anything solid in front of it shields it.
## It is hit on any face; nothing about it reflects. It joins "water_solid" so liquid rests on it, and not
## "ground"/"catwalk", so it can't be ledge-grabbed. Kicks do nothing to it (layer 1 is not set).
##
## AND gate of two receivers: wire both to one PowerTarget and set `all_required` on it; `invert` makes a NOT.
##
## Origin: the centre of a 16x16 tile (the cell a ConductorLayer files it under, like Button). Art is drawn in code (a
## housing with a lens that glows while powered and frosts over as the frost builds) until sprites exist.
##
## Saveable: `powered` and `time_left`. A restore snaps silently (frost comes back full if it was powered, else empty) and
## then re-derives from the live beam.
## Sounds `interactive/freeze_receiver_on` and `interactive/freeze_receiver_off` are in Audio.PLANNED.

signal powered_changed(on: bool)

## Seconds of sustained beam before the receiver powers; 0 = powers the frame the beam reaches it.
@export_range(0.0, 60.0, 0.05, "or_greater", "suffix:s") var dwell_time: float = 1.0
## Seconds the receiver stays powered after the beam leaves it; 0 = exactly as long as it is lit.
@export_range(0.0, 60.0, 0.05, "or_greater", "suffix:s") var hold_time: float = 0.3
@export var draw_placeholder: bool = true

const LIT_FRAMES := 2 ## A hit this many physics frames ago or less counts as lit (same as the laser receiver).
const QUIET_FRAMES := 3 ## No sound for a change this soon after load: the beam was already on.
const FROST_DECAY_PER_SEC := 1.0 ## Seconds of frost lost per second with no beam. Same rate as a basin's (WaterBasin.FROST_DECAY_PER_SEC).
const TILE_HALF := 8.0
const COLOR_BODY := Color(0.25, 0.27, 0.32)
const COLOR_EDGE := Color(0.55, 0.58, 0.65)
const COLOR_LENS_OFF := Color(0.1, 0.16, 0.28)
const COLOR_LENS_ON := Color(0.45, 0.85, 1.0)

var powered: bool = false
var _frost: float = 0.0
var _hit_frame: int = -1000
var _time_left: float = 0.0
var _ready_frame: int = 0

func _ready() -> void:
	add_to_group(&"power_source")  # what ConductorLayer scans to attach sources to circuits by adjacency
	queue_redraw()
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	add_to_group(&"water_solid")  # collision only; static, so carry is inert for it
	add_to_group(&"saveable")
	_ready_frame = Engine.get_physics_frames()

## Beam contract (FreezeTurret._dispatch): called every physics frame the beam ends on this body.
func on_freeze_hit(_point: Vector2, _direction: Vector2) -> void:
	_hit_frame = Engine.get_physics_frames()

func is_lit() -> bool:
	return Engine.get_physics_frames() - _hit_frame <= LIT_FRAMES

## Power-source contract (PowerTarget and conductor circuits read this).
func is_powered() -> bool:
	return powered

## Saveable contract (see game.gd).
func save_state() -> Dictionary:
	return {"powered": powered, "time_left": _time_left}

## Snaps with no sound. Emits powered_changed only if `powered` differs from the current value, so circuits and targets
## follow; the live beam takes over from the next physics frame.
func load_state(d: Dictionary) -> void:
	var was := powered
	powered = d.get("powered", false)
	_time_left = float(d.get("time_left", 0.0)) if powered else 0.0
	_frost = dwell_time if powered else 0.0
	_hit_frame = -1000
	queue_redraw()
	if powered != was:
		powered_changed.emit(powered)

func _physics_process(delta: float) -> void:
	if is_lit():
		if not powered:
			_frost = minf(_frost + delta, dwell_time)
			if _frost >= dwell_time:
				_set_powered(true)
		if powered:
			_frost = dwell_time  # lit and powered: frost is held full, and the hold restarts
			_time_left = hold_time
	else:
		_frost = maxf(_frost - FROST_DECAY_PER_SEC * delta, 0.0)
		if powered:
			_time_left = maxf(_time_left - delta, 0.0)
			if _time_left <= 0.0:
				_set_powered(false)
	if not powered and (_frost > 0.0 or is_lit()):
		queue_redraw()  # the lens frosts over as the frost builds

func _set_powered(on: bool) -> void:
	if on == powered:
		return
	powered = on
	if Engine.get_physics_frames() - _ready_frame > QUIET_FRAMES:
		Audio.play_at(&"interactive/freeze_receiver_on" if on else &"interactive/freeze_receiver_off", global_position)
	queue_redraw()
	powered_changed.emit(on)

# --- drawing -------------------------------------------------------------------------------------

func _draw() -> void:
	if not draw_placeholder:
		return
	draw_rect(Rect2(-TILE_HALF, -TILE_HALF, 16, 16), COLOR_BODY)
	draw_rect(Rect2(-TILE_HALF, -TILE_HALF, 16, 16), COLOR_EDGE, false, 1.0)
	var charge := 1.0 if powered else (clampf(_frost / dwell_time, 0.0, 1.0) if dwell_time > 0.0 else 0.0)
	var lens := COLOR_LENS_OFF.lerp(COLOR_LENS_ON, charge)
	if powered:
		var glow := COLOR_LENS_ON
		glow.a = 0.3
		draw_circle(Vector2.ZERO, 6.0, glow)
	draw_circle(Vector2.ZERO, 3.5, Color(0.1, 0.11, 0.14))
	draw_circle(Vector2.ZERO, 2.5, lens)
