@tool
extends StaticBody2D
## Arc receiver: a solid block that is a power SOURCE struck by an electric Arc (see power_target.gd for the contract).
## The bullet target's cousin for arcs. Emits `powered_changed(on)` and answers `is_powered()`; PowerTargets pick it in
## their `sources` list and conductor wires attach to it by adjacency, exactly like a Button.
##
## An Arc that ends on this body calls `on_arc_hit(point, direction)` once (see arc.gd); an arc is a single event, so
## each hit acts at once. Modes, like a button's and the bullet target's:
##   MOMENTARY  powered for `pulse_length` seconds (default 2.5, a little over an ArcTurret's default 2 s
##              `fire_interval`, so a turret firing straight at it holds it on) after each hit; a hit while powered
##              restarts the pulse with no new edge. Saves `powered` and `time_left` (arcs in flight are not saved,
##              so a restore mid-pulse would otherwise drop the power at once and act on its targets).
##   TOGGLE     each hit flips it. Saves `powered`.
##   TIMED      powered for `duration` seconds after a hit; a hit while powered restarts the countdown with no new
##              edge. Saves `powered` and `time_left`.
##
## Solid like any wall (layer 2, mask 0): an arc stops on it and anything solid in front of it shields it, the player
## stands on it and liquid rests on it ("water_solid"), and it is not "ground"/"catwalk", so it can't be ledge-grabbed.
## Kicks do nothing (layer 1 is not set). Struck on any face; nothing about it reflects. Only arcs move it: a laser,
## bullet or spark does nothing, and an arc that crosses a catwalk or glass first still counts.
##
## AND gate of two receivers: wire both to one PowerTarget and set `all_required` on it (arcs rarely arrive
## together, so use TIMED or a long pulse); `invert` makes a NOT.
##
## Origin: the centre of a 16x16 tile (the cell a ConductorLayer files it under, like Button). Art is drawn in code
## (a housing with a coil ring and a lens that glows while powered, a shrinking arc while a countdown runs and a ring
## flash per hit) until sprites exist. Sounds `interactive/arc_receiver_on` and `interactive/arc_receiver_off` are in
## Audio.PLANNED (played on a change of power, not within `QUIET_FRAMES` of load).
##
## Saveable: see the modes above; a restore snaps silently and emits `powered_changed` only on a change.

signal powered_changed(on: bool)

enum LatchMode { MOMENTARY, TOGGLE, TIMED }

@export var latch_mode: LatchMode = LatchMode.MOMENTARY:
	set(value):
		latch_mode = value
		notify_property_list_changed()  # shows/hides pulse_length and duration
		queue_redraw()
## MOMENTARY only: seconds powered after the last hit.
@export_range(0.05, 60.0, 0.05, "or_greater") var pulse_length: float = 2.5
## TIMED only: seconds powered after the last hit.
@export_range(0.1, 120.0, 0.1, "or_greater") var duration: float = 5.0
@export var draw_placeholder: bool = true

const QUIET_FRAMES := 3 ## No sound for a change this soon after load.
const FLASH_TIME := 0.18 ## Seconds of the ring flash per hit.
const TILE_HALF := 8.0
const COLOR_BODY := Color(0.2, 0.24, 0.32)
const COLOR_EDGE := Color(0.5, 0.62, 0.78)
const COLOR_LENS_OFF := Color(0.12, 0.18, 0.24)
const COLOR_LENS_ON := Color(0.35, 0.8, 1.0)
const COLOR_CORE := Color(0.9, 1.0, 1.0)

var powered: bool = false
var _time_left: float = 0.0
var _flash_t: float = 0.0
var _ready_frame: int = 0

func _ready() -> void:
	add_to_group(&"power_source")  # what ConductorLayer scans to attach sources to circuits by adjacency
	queue_redraw()
	set_process(false)  # runs only while a flash or a countdown needs redrawing
	if Engine.is_editor_hint():
		set_physics_process(false)
		return
	add_to_group(&"water_solid")  # collision only; static, so carry is inert for it
	add_to_group(&"saveable")
	_ready_frame = Engine.get_physics_frames()

func _validate_property(property: Dictionary) -> void:
	if property.name == "pulse_length" and latch_mode != LatchMode.MOMENTARY:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	elif property.name == "duration" and latch_mode != LatchMode.TIMED:
		property.usage = PROPERTY_USAGE_NO_EDITOR

## Arc contract (Arc._dispatch_hit()): called once, on the frame an arc ends on this body.
func on_arc_hit(_point: Vector2, _direction: Vector2) -> void:
	_flash_t = FLASH_TIME
	match latch_mode:
		LatchMode.TOGGLE:
			_set_powered(not powered)
		_:
			_time_left = _hold_length()  # a hit while powered restarts the countdown with no new edge
			_set_powered(true)
	_sync_process()
	queue_redraw()

## Power-source contract (PowerTarget and conductor circuits read this).
func is_powered() -> bool:
	return powered

## Saveable contract (see game.gd).
func save_state() -> Dictionary:
	if latch_mode == LatchMode.TOGGLE:
		return {"powered": powered}
	return {"powered": powered, "time_left": _time_left}

## Snaps with no sound or flash. Emits powered_changed only if `powered` differs from the current value; a timed
## or momentary countdown then runs out from the saved time.
func load_state(d: Dictionary) -> void:
	var was := powered
	powered = d.get("powered", false)
	_time_left = 0.0
	if powered and latch_mode != LatchMode.TOGGLE:
		_time_left = float(d.get("time_left", 0.0))
		if _time_left <= 0.0:
			_time_left = _hold_length()  # a snapshot without a time: start a fresh countdown
	_flash_t = 0.0
	_sync_process()
	queue_redraw()
	if powered != was:
		powered_changed.emit(powered)

func _physics_process(delta: float) -> void:
	if latch_mode == LatchMode.TOGGLE or not powered:
		return
	_time_left = maxf(_time_left - delta, 0.0)
	if _time_left <= 0.0:
		_set_powered(false)
		_sync_process()
		queue_redraw()

func _process(delta: float) -> void:
	_flash_t = maxf(_flash_t - delta, 0.0)
	queue_redraw()
	if _flash_t <= 0.0 and not _timer_running():
		set_process(false)

func _hold_length() -> float:
	return duration if latch_mode == LatchMode.TIMED else pulse_length

func _timer_running() -> bool:
	return powered and latch_mode != LatchMode.TOGGLE

func _sync_process() -> void:
	set_process(_flash_t > 0.0 or _timer_running())

func _set_powered(on: bool) -> void:
	if on == powered:
		return
	powered = on
	if not on:
		_time_left = 0.0
	if Engine.get_physics_frames() - _ready_frame > QUIET_FRAMES:
		Audio.play_at(&"interactive/arc_receiver_on" if on else &"interactive/arc_receiver_off", global_position)
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
	# coil ring round the lens, to read as the arc turret's counterpart
	draw_arc(Vector2.ZERO, 5.0, 0.0, TAU, 16, Color(COLOR_EDGE, 0.8), 1.0)
	draw_circle(Vector2.ZERO, 3.5, Color(0.1, 0.11, 0.14))
	draw_circle(Vector2.ZERO, 2.5, lens)
	if _timer_running() and not Engine.is_editor_hint():
		var left := clampf(_time_left / maxf(_hold_length(), 0.001), 0.0, 1.0)
		draw_arc(Vector2.ZERO, 7.0, -PI * 0.5, -PI * 0.5 + TAU * left, 24, COLOR_LENS_ON, 1.0)
	if _flash_t > 0.0:
		var t := 1.0 - _flash_t / FLASH_TIME
		draw_arc(Vector2.ZERO, 4.0 + 4.0 * t, 0.0, TAU, 16, Color(COLOR_CORE, 1.0 - t), 1.5)
