@tool
class_name LogicPulse
extends LogicNode
## Pulse: a rising edge of the combined input switches the output on for `duration` seconds, whatever the input
## does next (it can be released at once). A new rising edge while the output is on restarts the time with no new
## `powered_changed`, so a stream of presses keeps it on; falling edges do nothing (`invert_input` makes the falling
## edge the trigger). Use it to turn a held or latched source into a short event: a rising-edge device (arc turret,
## cannon, step-mode mirror, camera cue) fires once however long the button stays down, or a door that opens for
## a fixed time.
##
## Startup: off, and an input already on at load is not an edge. Save: the seconds left.

## Seconds the output stays on after the last rising edge.
@export_range(0.05, 60.0, 0.05, "or_greater") var duration: float = 1.0

var _left: float = -1.0

func _initial_output() -> bool:
	return false

func _on_input_changed(on: bool) -> void:
	if not on:
		return
	_left = duration
	set_physics_process(true)
	_set_output(true)

func _physics_process(delta: float) -> void:
	if _left < 0.0:
		set_physics_process(false)
		return
	_left -= delta
	if _left <= 0.0:
		_left = -1.0
		set_physics_process(false)
		_set_output(false)

func _tag() -> String:
	return "PULSE"

func _save_extra(d: Dictionary) -> void:
	d["left"] = _left

func _load_extra(d: Dictionary) -> void:
	_left = d.get("left", -1.0)
	set_physics_process(_left >= 0.0)
