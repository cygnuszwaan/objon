@tool
class_name LogicLatch
extends LogicNode
## Latch (set / reset memory): the output goes on while a `sources` input is on and then STAYS on after it lets go,
## until a `reset_sources` input switches it off. Both are levels, and reset dominates: while any reset source is on
## the output is off and a set cannot take; when the reset lets go a set that is still on latches again at once.
## Many sources on either side: `sources` combine as usual (`all_required`, `invert_input`), `reset_sources` are any
## one of them. `start_on` begins the level latched (a reset still clears it).
##
## Where a TOGGLE button flips on every press, this is "set by A, cleared by B", so two buttons, a receiver and a
## sensor can open and close one door, and a plate can arm what a button disarms.
##
## Startup: `(start_on or set) and not reset`, with no edge. Save: the output and the reset level.

## Any one of these on clears the latch and holds it clear.
@export var reset_sources: Array[Node] = []:
	set(value):
		reset_sources = value
		if PowerTarget.fit_flags(invert_reset_sources, reset_sources.size()):
			notify_property_list_changed()
		if is_node_ready():
			_reconnect()
			queue_redraw()
			update_configuration_warnings()
## One checkbox per entry of `reset_sources`, in the same order: tick it to read that reset source as NOT.
@export var invert_reset_sources: Array[bool] = []:
	set(value):
		invert_reset_sources = value
		queue_redraw()
		_refresh_inputs()
## The latch is on at load, until a reset.
@export var start_on: bool = false

var _reset: bool = false

func _watched() -> Array[Node]:
	return sources + reset_sources

func _read_reset() -> bool:
	return _has_valid(reset_sources) and _combine(reset_sources, false, invert_reset_sources)

func _snap_inputs() -> void:
	super()
	_reset = _read_reset()

func _initial_output() -> bool:
	return (start_on or _input) and not _reset

func _on_inputs_changed() -> void:
	_reset = _read_reset()
	_input = _read_input()
	_set_output((powered or _input) and not _reset)

func _tag() -> String:
	return "LATCH"

func _link_lists() -> Array:
	return [[sources, LINK_COLOR, invert_sources], [reset_sources, LINK_COLOR_RESET, invert_reset_sources]]

func _save_extra(d: Dictionary) -> void:
	d["reset"] = _reset

func _load_extra(d: Dictionary) -> void:
	_reset = d.get("reset", false)
