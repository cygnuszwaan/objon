extends AnimatableBody2D

# Moving platform. Loops forever: wait at the start, travel to the far end, wait there, travel back.
#
# Per-instance tuning is exported (travel_offset, travel_time, dwell_at_start, dwell_at_end).
# To open it up further:
#   - multi-stage routes: replace the two explicit legs in _build_sequence() with a loop over a list
#     of stages (offset / travel time / dwell each) — nothing else in this script cares how many legs
#     there are
#
# How the player gets carried: NOT by this script and NOT by reparenting. CharacterBody2D's
# move_and_slide() already reads the velocity of the floor body it's standing on and moves along with
# it, so riding needs no player.gd code. That only works if the platform actually moves during the
# physics step, which is why the tween below runs in TWEEN_PROCESS_PHYSICS and sync_to_physics is on
# (both also keep it correct if Physics Interpolation is enabled).
#
# Ledge-hanging: the platform joins group "ground" so player.gd's _is_hangable_surface() accepts it,
# and player.gd follows any hung-from AnimatableBody2D by shifting its pinned hang position by the
# body's per-frame movement. Delete the add_to_group() line below to make the platform un-grabbable.

# Power: powered = running, unpowered = paused where it is (the tween is paused, so a rider just stops with
# it). set_powered() -> _tween.pause()/play(). With nothing wired to its PowerTarget child it runs forever.
# `invert` flips that (read by the PowerTarget child).
@export var invert: bool = false
## Seconds between the wired power changing and this device following it (read by the PowerTarget child). Every change
## waits the same time, so a short pulse stays a short pulse; the startup state is never delayed. 0 = at once.
@export_range(0.0, 30.0, 0.05, "or_greater") var delay: float = 0.0

## Where the far end is, RELATIVE TO WHERE THE PLATFORM IS PLACED in the editor: direction and
## distance in one vector. (96, 0) = 96px (6 tiles) right; (0, -64) = 64px up.
@export var travel_offset: Vector2 = Vector2(96.0, 0.0)
## Seconds for ONE leg (start -> far end, or back again).
@export_range(0.1, 20.0, 0.1, "or_greater") var travel_time: float = 2.0
## Seconds paused at the placed position, before each outbound leg.
@export_range(0.0, 20.0, 0.1, "or_greater") var dwell_at_start: float = 1.0
## Seconds paused at the far end, before each return leg.
@export_range(0.0, 20.0, 0.1, "or_greater") var dwell_at_end: float = 1.0

var _start_position: Vector2
var _tween: Tween  # kept so set_powered() can pause()/play() it
var _running: bool = true

func _ready() -> void:
	sync_to_physics = true  # already the default, but the whole "player rides for free" design depends on it
	add_to_group("ground")  # what makes the ledge hangable — see the header note
	add_to_group("water_solid")  # water-mechanic.md Phase 9.1/9.2: lets particles rest on/be carried by this
	add_to_group("saveable")
	_start_position = position
	_tween = _build_sequence()
	if not _running:
		_tween.pause()

## Saveable contract (see game.gd). The platform's whole state is where it is in the loop: `phase` is the
## tween's elapsed time within one period.
func save_state() -> Dictionary:
	var phase := 0.0
	if _tween != null and _tween.is_valid():
		phase = fposmod(_tween.get_total_elapsed_time(), _period())
	return {"phase": phase, "running": _running}

## A Tween can't be seeked, so the loop is rebuilt from the start and fast-forwarded to the saved phase in
## small slices (each tweener then starts from the right position).
func load_state(d: Dictionary) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	position = _start_position
	_tween = _build_sequence()
	var remaining: float = d.get("phase", 0.0)
	while remaining > 0.0:
		var slice := minf(remaining, 0.05)
		_tween.custom_step(slice)
		remaining -= slice
	_running = d.get("running", true)
	if not _running:
		_tween.pause()
	reset_physics_interpolation()

## Power contract (see power_target.gd): powered = running.
func set_powered(on: bool) -> void:
	_running = on
	if _tween == null or not _tween.is_valid():
		return
	if on:
		_tween.play()
	else:
		_tween.pause()

## One full loop of _build_sequence(): dwell, out, dwell, back.
func _period() -> float:
	return dwell_at_start + travel_time + dwell_at_end + travel_time

func _build_sequence() -> Tween:
	var tween := create_tween()
	tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)  # move in lockstep with the physics step
	tween.set_loops()  # no argument = loop forever
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)  # eases in/out of each leg so the player isn't jolted at the ends

	tween.tween_interval(dwell_at_start)
	tween.tween_property(self, "position", _start_position + travel_offset, travel_time)
	tween.tween_interval(dwell_at_end)
	tween.tween_property(self, "position", _start_position, travel_time)
	return tween
