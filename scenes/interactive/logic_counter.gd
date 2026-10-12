@tool
class_name LogicCounter
extends LogicNode
## Counter: the output goes on after `count_to` rising edges of its sources. Every source counts on its own (a
## second source rising while the first is still held is a new edge), so three buttons pressed once each, or one
## button pressed three times, both reach 3; `invert_input` counts falling edges instead and `all_required` does
## not apply (it is hidden). Edges past `count_to` are ignored.
##
## Reset: while any `reset_sources` input is on, the count is held at 0, the output is off and edges are ignored
## (they are not saved up). `auto_reset_time` above 0 clears the count that many seconds after the output goes on
## (a timed unlock); 0 keeps it on until a reset.
##
## Startup: count 0, no edge counted, output off. Save: the count, each source's last level, the reset level and the
## auto-reset seconds left. The count is also readable as `count`, e.g. by a test or an overlay.

## Rising edges needed.
@export_range(1, 99, 1, "or_greater") var count_to: int = 3
## Any one of these on holds the counter cleared.
@export var reset_sources: Array[Node] = []:
	set(value):
		reset_sources = value
		if is_node_ready():
			_reconnect()
			queue_redraw()
			update_configuration_warnings()
## Seconds after reaching `count_to` before the count and output clear by themselves (0 = never).
@export_range(0.0, 60.0, 0.1, "or_greater") var auto_reset_time: float = 0.0

var count: int = 0
var _prev: Array[bool] = [] ## Each source's last level, in `sources` order.
var _reset: bool = false
var _hold_left: float = -1.0

func _validate_property(property: Dictionary) -> void:
	if property.name == &"all_required":
		property.usage = PROPERTY_USAGE_NO_EDITOR  # each source counts on its own

func _watched() -> Array[Node]:
	return sources + reset_sources

func _levels() -> Array[bool]:
	var levels: Array[bool] = []
	for source in sources:
		levels.append(_is_valid_source(source) and (source.is_powered() != invert_input))
	return levels

func _read_reset() -> bool:
	return _has_valid(reset_sources) and _combine(reset_sources, false)

func _snap_inputs() -> void:
	_prev = _levels()
	_reset = _read_reset()

func _initial_output() -> bool:
	return false

func _on_inputs_changed() -> void:
	var levels := _levels()
	var rises := 0
	for i in levels.size():
		if levels[i] and not (i < _prev.size() and _prev[i]):
			rises += 1
	_prev = levels
	_reset = _read_reset()
	if _reset:
		_clear()
		return
	if rises == 0 or count >= count_to:
		return
	count = mini(count + rises, count_to)
	if count >= count_to:
		_set_output(true)
		if auto_reset_time > 0.0:
			_hold_left = auto_reset_time
			set_physics_process(true)

func _clear() -> void:
	count = 0
	_hold_left = -1.0
	_set_output(false)

func _physics_process(delta: float) -> void:
	if _hold_left < 0.0:
		set_physics_process(false)
		return
	_hold_left -= delta
	if _hold_left <= 0.0:
		set_physics_process(false)
		_clear()

func _tag() -> String:
	return "CNT"

func _link_lists() -> Array:
	return [[sources, LINK_COLOR], [reset_sources, LINK_COLOR_RESET]]

func _save_extra(d: Dictionary) -> void:
	d["count"] = count
	d["prev"] = _prev.duplicate()
	d["reset"] = _reset
	d["hold"] = _hold_left

func _load_extra(d: Dictionary) -> void:
	count = d.get("count", 0)
	_prev.clear()
	for lit in d.get("prev", []):
		_prev.append(bool(lit))
	_reset = d.get("reset", false)
	_hold_left = d.get("hold", -1.0)
	set_physics_process(_hold_left >= 0.0)
