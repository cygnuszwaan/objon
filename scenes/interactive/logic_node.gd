@tool
class_name LogicNode
extends Node2D
## Base of the logic nodes (LogicDelay, LogicLatch, LogicCounter, LogicPulse): small power SOURCES that read other
## sources and give back a state of their own. They answer `is_powered()` and emit `powered_changed(on)`, so a
## device's PowerTarget picks one in its `sources` list exactly like a Button.
##
## They are not wire objects. A logic node is not a PowerTarget and does not join group "power_source", so a
## ConductorLayer never attaches to it: its inputs are the exported `sources` lists (a typed node-picker, any node
## with `is_powered()`: buttons, receivers, plates, sensors, the camera cue's pass-through, other logic nodes) and
## its output is picked as a source by whatever it should drive. A conductor circuit is generated at run time and
## cannot be picked, so route a circuit into a logic node by putting a Button, sensor or other source on that wire.
## No collision, no art and no sound at run time; the devices it drives make the noise. The origin is free to place
## (the editor draws a small tag and the links; nothing reads the position).
##
## INPUT: `sources` combine like a PowerTarget's (any one lights it; `all_required` needs every one), then
## `invert_input` flips the level. `invert_sources` is a checkbox per source (same size as `sources`, kept in step by
## the `sources` setter) that reads that one source as NOT before they combine; the Latch's and Counter's
## `reset_sources` have `invert_reset_sources` the same way. A source with no entry is not inverted. No valid source
## reads as off, never as "inverted on".
##
## STARTUP: the first state is derived from the inputs at once and is not an edge: nothing counts, pulses or waits.
## `is_powered()` derives it on demand, so a device whose own startup apply runs first still reads the right
## state; a state derived from sources that are not ready yet is re-derived by the deferred call from `_ready()`.
##
## LOOPS: logic nodes may read each other, and a loop that cannot settle (A inverts B, B follows A) would recurse
## through the signals. A shared depth guard (MAX_DEPTH) cuts it with one warning, and `get_warnings()` names a
## node that can reach itself.
##
## SAVE: group "saveable", joined in `_ready()`. `save_state()` holds the output, the last input level and what a
## subclass adds (pending timers, counts). `load_state()` snaps silently, emits `powered_changed` only on a change
## and then re-reads the inputs once (deferred) without treating that as an edge, so a source restored after this
## node cannot fake one. Timers are plain countdowns in `_physics_process()` (never `create_timer()`), so pausing
## freezes them.
##
## SUBCLASSES override the virtuals below and never `_ready()`/`_physics_process()` without calling `super()`.
## Authored values are exports and only read; runtime state is the plain variables.

signal powered_changed(on: bool)

const MAX_DEPTH := 16 ## Signal recursion cut-off across all logic nodes.
const LINK_COLOR := Color(0.4, 0.85, 1.0, 0.8)
const LINK_COLOR_RESET := Color(1.0, 0.6, 0.2, 0.8)
const LINK_COLOR_INVERTED := Color(1.0, 0.35, 0.65, 0.9) ## A source ticked in an invert list.
const TAG_COLOR := Color(0.75, 0.55, 1.0, 0.9)

static var _depth: int = 0
static var _depth_warned: bool = false

## The input sources (any one of them lights the input, or every one with `all_required`).
@export var sources: Array[Node] = []:
	set(value):
		sources = value
		if PowerTarget.fit_flags(invert_sources, sources.size()):
			notify_property_list_changed()
		if is_node_ready():
			_reconnect()
			queue_redraw()
			update_configuration_warnings()
## One checkbox per entry of `sources`, in the same order: tick it to read that source as NOT.
@export var invert_sources: Array[bool] = []:
	set(value):
		invert_sources = value
		queue_redraw()
		_refresh_inputs()
## The input needs every source on, not any one.
@export var all_required: bool = false:
	set(value):
		all_required = value
		_refresh_inputs()
## Flips the input level (a Pulse then fires on the falling edge, a Delay waits on the absence).
@export var invert_input: bool = false:
	set(value):
		invert_input = value
		_refresh_inputs()
## Editor overlay: a line to each source.
@export var draw_links: bool = true

var powered: bool = false ## The output.
var authoring_overlay: bool = false ## Draws the tag and links. Set in `_ready()` in the editor; a runtime level editor can set it too.
var _input: bool = false ## The last combined input level.
var _initialised: bool = false
var _initialising: bool = false
var _connected: Array[Node] = []

func _ready() -> void:
	authoring_overlay = Engine.is_editor_hint()
	set_physics_process(false)
	if Engine.is_editor_hint():
		set_process(true)  # keeps the overlay current while sources are edited
		return
	set_process(false)
	add_to_group(&"saveable")  # joined here, never deferred (see Checkpoint and save/restore)
	_reconnect()
	call_deferred(&"_ensure_initial")

func _process(_delta: float) -> void:
	queue_redraw()  # editor only (see _ready)

## The output. Derives the startup state first if nothing has yet.
func is_powered() -> bool:
	_ensure_initial()
	return powered

# --- virtuals ------------------------------------------------------------------------------------

## Nodes whose `powered_changed` this node listens to. Subclasses with a second list add it.
func _watched() -> Array[Node]:
	return sources

## The input levels have been read for the first time (or re-read after a restore): store them without acting.
func _snap_inputs() -> void:
	_input = _read_input()

## The output at startup, from `_input` and whatever `_snap_inputs()` stored.
func _initial_output() -> bool:
	return _input

## Some watched source changed. The default handles a single combined input: it calls `_on_input_changed()` on a
## change of the combined level only.
func _on_inputs_changed() -> void:
	var now := _read_input()
	if now == _input:
		return
	_input = now
	_on_input_changed(now)

## The combined input level changed (default `_on_inputs_changed()` only).
func _on_input_changed(_on: bool) -> void:
	pass

func _save_extra(_d: Dictionary) -> void:
	pass

func _load_extra(_d: Dictionary) -> void:
	pass

## Lists drawn as links in the editor: [[nodes, colour, invert flags], ...] (the flags are optional; a ticked source is drawn pink).
func _link_lists() -> Array:
	return [[sources, LINK_COLOR, invert_sources]]

func _tag() -> String:
	return "LOGIC"

func _extra_warnings() -> PackedStringArray:
	return PackedStringArray()

# --- plumbing ------------------------------------------------------------------------------------

func _ensure_initial() -> void:
	if _initialised or _initialising or Engine.is_editor_hint():
		return
	_initialising = true
	_snap_inputs()
	powered = _initial_output()
	_initialising = false
	_initialised = true

func _set_output(on: bool) -> void:
	if on == powered:
		return
	powered = on
	powered_changed.emit(on)

func _on_source_changed(_on: bool) -> void:
	if not _initialised:
		_ensure_initial()  # the change is part of the state it just derived
		return
	if _initialising:
		return
	if _depth >= MAX_DEPTH:
		if not _depth_warned:
			_depth_warned = true
			push_warning("%s: logic nodes are feeding each other in a loop that does not settle; cutting it." % name)
		return
	_depth += 1
	_on_inputs_changed()
	_depth -= 1

func _refresh_inputs() -> void:
	if Engine.is_editor_hint() or not is_node_ready() or not _initialised:
		return
	_on_source_changed(false)

func _reconnect() -> void:
	if Engine.is_editor_hint():
		return
	for old in _connected:
		if is_instance_valid(old) and old.powered_changed.is_connected(_on_source_changed):
			old.powered_changed.disconnect(_on_source_changed)
	_connected.clear()
	for source in _watched():
		if source == null or not source.has_signal(&"powered_changed") or source == self:
			continue
		if source.powered_changed.is_connected(_on_source_changed):
			continue
		source.powered_changed.connect(_on_source_changed)
		_connected.append(source)
	if _initialised:
		_snap_inputs()  # the lists changed under a running node: re-baseline, no edge

func _read_input() -> bool:
	if not _has_valid(sources):
		return false
	return _combine(sources, all_required, invert_sources) != invert_input

## Any one lit (or all lit with `all`) among the valid entries of `list`; entry i is read as NOT if `flags[i]` is ticked.
func _combine(list: Array[Node], all: bool, flags: Array[bool] = []) -> bool:
	var seen_any := false
	for i in list.size():
		var source := list[i]
		if not _is_valid_source(source):
			continue
		seen_any = true
		var lit: bool = source.is_powered() != PowerTarget.flag_at(flags, i)
		if all and not lit:
			return false
		if not all and lit:
			return true
	return seen_any and all

func _has_valid(list: Array[Node]) -> bool:
	for source in list:
		if _is_valid_source(source):
			return true
	return false

func _is_valid_source(source: Node) -> bool:
	return source != null and is_instance_valid(source) and source != self and source.has_method(&"is_powered")

func save_state() -> Dictionary:
	var d := {"powered": powered, "input": _input}
	_save_extra(d)
	return d

func load_state(d: Dictionary) -> void:
	_initialised = true
	_initialising = false
	_input = d.get("input", _input)
	_load_extra(d)
	var on: bool = d.get("powered", powered)
	var changed := on != powered
	powered = on
	if changed:
		powered_changed.emit(on)
	call_deferred(&"_snap_inputs")  # re-baseline against the restored sources, without an edge

# --- authoring -----------------------------------------------------------------------------------

## Plain method, so a runtime level validator can reuse it; `_get_configuration_warnings()` calls it.
func get_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not _has_valid(sources):
		warnings.append("No sources: pick the power source(s) in `sources`. Until there is one the output stays off.")
	for list in _link_lists():
		for source in list[0]:
			if source == self:
				warnings.append("A logic node cannot read itself.")
			elif source != null and not source.has_method(&"is_powered"):
				warnings.append("%s has no is_powered(): it isn't a power source." % source.name)
	if _loops_to(self, {}):
		warnings.append("This node can reach itself through other logic nodes (a loop).")
	warnings.append_array(_extra_warnings())
	return warnings

func _get_configuration_warnings() -> PackedStringArray:
	return get_warnings()

func _loops_to(target: LogicNode, seen: Dictionary) -> bool:
	for source in _watched():
		if not source is LogicNode:
			continue
		if source == target:
			return true
		if seen.has(source):
			continue
		seen[source] = true
		if (source as LogicNode)._loops_to(target, seen):
			return true
	return false

func _draw() -> void:
	if not authoring_overlay:
		return
	draw_rect(Rect2(-8.0, -5.0, 16.0, 10.0), TAG_COLOR, false, 1.0)
	draw_string(ThemeDB.fallback_font, Vector2(-7.0, 3.0), _tag(), HORIZONTAL_ALIGNMENT_LEFT, 14.0, 7, TAG_COLOR)
	if not draw_links:
		return
	for list in _link_lists():
		var flags: Array[bool] = []
		if list.size() > 2:
			flags = list[2]
		for i in list[0].size():
			var source: Node = list[0][i]
			if source == null or not is_instance_valid(source) or not source is Node2D:
				continue
			var color: Color = LINK_COLOR_INVERTED if PowerTarget.flag_at(flags, i) else list[1]
			var end := to_local((source as Node2D).global_position)
			draw_line(Vector2.ZERO, end, color, 1.0)
			draw_circle(end, 2.5, color)
