@tool
class_name LogicDelay
extends LogicNode
## Delay: the output follows the combined input, late. A rise of the input switches the output on after
## `on_delay` seconds, a fall switches it off after `off_delay`; each only if the input has stayed there the whole
## time, so a flicker shorter than the delay never gets through (an on-delay filters short presses, an off-delay
## stretches them). A zero delay is instant in that direction, and both zero is a plain pass-through (a warning).
## Use it to let a camera cue arrive before the door opens, to open a second door a beat after the first, or with an
## inverted input to act on the absence of something.
##
## Startup: the output equals the input at once, with no wait. Save: the pending target and the seconds left, so a
## restore resumes the wait.

## Seconds the input must stay on before the output rises (0 = at once).
@export_range(0.0, 30.0, 0.05, "or_greater") var on_delay: float = 1.0
## Seconds the input must stay off before the output falls (0 = at once).
@export_range(0.0, 30.0, 0.05, "or_greater") var off_delay: float = 0.0

var _target: bool = false ## The output level the running wait ends in.
var _timer_left: float = -1.0 ## Negative = no wait is running.

func _on_input_changed(on: bool) -> void:
	if on == powered:
		_timer_left = -1.0  # back where the output already is: cancel the wait
		return
	var wait := on_delay if on else off_delay
	if wait <= 0.0:
		_timer_left = -1.0
		_set_output(on)
		return
	_target = on
	_timer_left = wait
	set_physics_process(true)

func _physics_process(delta: float) -> void:
	if _timer_left < 0.0:
		set_physics_process(false)
		return
	_timer_left -= delta
	if _timer_left <= 0.0:
		_timer_left = -1.0
		set_physics_process(false)
		_set_output(_target)

func _tag() -> String:
	return "DLY"

func _save_extra(d: Dictionary) -> void:
	d["target"] = _target
	d["timer"] = _timer_left

func _load_extra(d: Dictionary) -> void:
	_target = d.get("target", false)
	_timer_left = d.get("timer", -1.0)
	set_physics_process(_timer_left >= 0.0)

func _extra_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if on_delay <= 0.0 and off_delay <= 0.0:
		warnings.append("Both delays are 0: the output just follows the input.")
	return warnings
